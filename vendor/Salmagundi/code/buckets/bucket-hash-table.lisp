(cl:in-package #:salmagundi/bucket)

;;; kiln: the entries are kept in the order SBCL's hash tables iterate in
;;; too: insertion order, a removed entry's place reused by the next
;;; insertion (the last freed first). An entry is (KEY VALUE . INDEX),
;;; INDEX its place in ORDER; the buckets hold the same entries. kiln's
;;; compiler on kiln must make the KIR SBCL makes, and macro expanders
;;; iterate over hash tables (Khazern's destructuring temporaries).

(defclass bucket-client (salmagundi:standard-client) ())

(defclass bucket-hash-table (salmagundi:hash-table)
  ((size :accessor %bucket-hash-table-size
         :reader salmagundi:hash-table-size
         :initarg :size
         :initform 16)
   (data :accessor hash-table-data)
   (count :accessor %bucket-hash-table-count
          :reader salmagundi:hash-table-count
          :initform 0)
   (order :accessor hash-table-order)
   (fill :accessor hash-table-fill :initform 0)
   (free :accessor hash-table-free :initform '())))

(defmethod initialize-instance :after ((hash-table bucket-hash-table) &key)
  (setf (hash-table-data hash-table)
        (make-array (salmagundi:hash-table-size hash-table)
                    :initial-element '())
        (hash-table-order hash-table)
        (make-array (max 4 (salmagundi:hash-table-size hash-table))
                    :initial-element nil)))

(defmethod salmagundi:make-hash-table ((client bucket-client) &rest initargs
                                       &key test size rehash-size rehash-threshold)
  (declare (ignore test size rehash-size rehash-threshold))
  (apply #'make-instance 'bucket-hash-table initargs))

(defmethod salmagundi:make-hash-table-iterator ((hash-table bucket-hash-table))
  (let ((position 0))
    (lambda ()
      (loop
        (when (>= position (hash-table-fill hash-table))
          (return nil))
        (let ((entry (svref (hash-table-order hash-table) position)))
          (incf position)
          (when entry
            (return (values t (car entry) (cadr entry)))))))))

(defun grow-and-rehash (hash-table)
  (with-accessors ((rehash-size salmagundi:hash-table-rehash-size)
                   (size salmagundi:hash-table-size)
                   (hash-function salmagundi:hash-table-hash-function))
      hash-table
    (let* ((new-size (if (integerp rehash-size)
                         (+ size rehash-size)
                         (round (* size rehash-size))))
           (new-data (make-array new-size :initial-element '()))
           (order (hash-table-order hash-table)))
      (dotimes (i (hash-table-fill hash-table))
        (let ((entry (svref order i)))
          (when entry
            (push entry (aref new-data (mod (funcall hash-function (car entry)) new-size))))))
      (setf (hash-table-data hash-table) new-data
            (%bucket-hash-table-size hash-table) new-size))))

(defun maybe-grow-and-rehash (hash-table)
  (when (> (salmagundi:hash-table-count hash-table)
           (* (salmagundi:hash-table-size hash-table)
              (salmagundi:hash-table-rehash-threshold hash-table)))
    (grow-and-rehash hash-table)))

(defmacro with-entry ((entries-index entries entry key hash-table) &body body)
  (let ((key-hash (gensym)))
    `(let* ((,key-hash (funcall (salmagundi:hash-table-hash-function ,hash-table)
                                ,key))
            (,entries-index (mod ,key-hash (salmagundi:hash-table-size ,hash-table)))
            (,entries (aref (hash-table-data ,hash-table) index))
            (,entry (assoc ,key entries :test (salmagundi:hash-table-test ,hash-table))))
       ,@body)))

(defun new-entry-index (hash-table)
  (if (hash-table-free hash-table)
      (pop (hash-table-free hash-table))
      (let ((index (hash-table-fill hash-table))
            (order (hash-table-order hash-table)))
        (when (= index (length order))
          (let ((new (make-array (* 2 (length order)) :initial-element nil)))
            (replace new order)
            (setf (hash-table-order hash-table) new)))
        (setf (hash-table-fill hash-table) (1+ index))
        index)))

(defmethod (setf salmagundi:gethash) (value key (hash-table bucket-hash-table) &optional default)
  (declare (ignore default))
  (with-entry (index entries entry key hash-table)
    (cond (entry
           (setf (cadr entry) value))
          (t
           (let* ((position (new-entry-index hash-table))
                  (entry (list* key value position)))
             (setf (svref (hash-table-order hash-table) position) entry)
             (push entry (aref (hash-table-data hash-table) index)))
           (incf (%bucket-hash-table-count hash-table))
           (maybe-grow-and-rehash hash-table))))
  value)

(defmethod salmagundi:gethash (key (hash-table bucket-hash-table) &optional default)
  (with-entry (index entries entry key hash-table)
    (if (null entry)
        (values default nil)
        (values (cadr entry) t))))

(defmethod salmagundi:remhash (key (hash-table bucket-hash-table))
  (with-entry (index entries entry key hash-table)
    (unless (null entry)
      (setf (aref (hash-table-data hash-table) index)
            (delete entry entries :test #'eq))
      (setf (svref (hash-table-order hash-table) (cddr entry)) nil)
      (push (cddr entry) (hash-table-free hash-table))
      (decf (%bucket-hash-table-count hash-table)))
    (not (null entry))))

(defmethod salmagundi:clrhash ((hash-table bucket-hash-table))
  (fill (hash-table-data hash-table) '())
  (fill (hash-table-order hash-table) nil)
  (setf (%bucket-hash-table-count hash-table) 0
        (hash-table-fill hash-table) 0
        (hash-table-free hash-table) '())
  hash-table)

(defmethod salmagundi:maphash (function (hash-table bucket-hash-table))
  ;; The entries are read as the function may change the table (CLHS
  ;; 3.6: it may set or remove the current entry).
  (let ((order (hash-table-order hash-table)))
    (dotimes (i (hash-table-fill hash-table))
      (let ((entry (svref order i)))
        (when entry
          (funcall function (car entry) (cadr entry)))))))
