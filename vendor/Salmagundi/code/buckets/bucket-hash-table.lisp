(cl:in-package #:salmagundi/bucket)

;;; kiln: rewritten for speed and for SBCL's iteration order.
;;;
;;; Order: the entries are kept in the order SBCL's hash tables iterate in
;;; too: insertion order, a removed entry's place reused by the next
;;; insertion (the last freed first). kiln's compiler on kiln must make the
;;; KIR SBCL makes, and macro expanders iterate over hash tables (Khazern's
;;; destructuring temporaries).
;;;
;;; Speed: what GETHASH needs is in one simple vector, the table's CORE,
;;; read from the instance at a fixed location (no accessor calls); EQ,
;;; EQL and EQUAL are compared inline. An entry is (KEY VALUE . INDEX),
;;; INDEX its place in the ORDER vector; the buckets hold the same entries.

(defclass bucket-client (salmagundi:standard-client) ())

(defclass bucket-hash-table (salmagundi:hash-table)
  ((size :initarg :size :initform 16)
   (core :accessor hash-table-core)))

;;; The core's elements.
(defconstant +data+ 0)                  ; simple vector of buckets
(defconstant +size+ 1)                  ; number of buckets, a power of two
(defconstant +count+ 2)
(defconstant +test-code+ 3)             ; 0 EQ, 1 EQL, 2 EQUAL, 3 other
(defconstant +test+ 4)                  ; the test function
(defconstant +hash+ 5)                  ; the hash function
(defconstant +order+ 6)                 ; simple vector of entries or NIL
(defconstant +fill+ 7)                  ; places of ORDER used so far
(defconstant +free+ 8)                  ; freed places, last freed first
(defconstant +limit+ 9)                 ; the count that makes the table grow
(defconstant +core-length+ 10)

(defvar *core-location* nil)

(declaim (inline core))
(defun core (hash-table)
  (kiln.sys:%primop :standard-instance-access hash-table *core-location*))

(defun test-code (test)
  (cond ((or (eq test 'eq) (eq test #'eq)) 0)
        ((or (eq test 'eql) (eq test #'eql)) 1)
        ((or (eq test 'equal) (eq test #'equal)) 2)
        (t 3)))

(defun growth-limit (hash-table size)
  (floor (* size (salmagundi:hash-table-rehash-threshold hash-table))))

(defmethod initialize-instance :after ((hash-table bucket-hash-table) &key)
  ;; kiln: a power of two, so that the bucket of a hash is its low bits.
  (let* ((size (let ((n 1)) (loop while (< n (slot-value hash-table 'size)) do (setf n (* n 2))) n))
         (core (make-array +core-length+))
         (test (salmagundi:hash-table-test hash-table))
         (hash (salmagundi:hash-table-hash-function hash-table)))
    (setf (svref core +data+) (make-array size :initial-element '())
          (svref core +size+) size
          (svref core +count+) 0
          (svref core +test-code+) (test-code test)
          (svref core +test+) (if (functionp test) test (fdefinition test))
          (svref core +hash+) (if (functionp hash) hash (fdefinition hash))
          (svref core +order+) (make-array (max 4 size) :initial-element nil)
          (svref core +fill+) 0
          (svref core +free+) '()
          (svref core +limit+) (growth-limit hash-table size))
    (setf (hash-table-core hash-table) core)
    (unless *core-location*
      (setf *core-location*
            (clostrophilia:slot-definition-location
             (find 'core (clostrophilia:class-slots (class-of hash-table))
                   :key #'clostrophilia:slot-definition-name))))))

(defmethod salmagundi:make-hash-table ((client bucket-client) &rest initargs
                                       &key test size rehash-size rehash-threshold)
  (declare (ignore test size rehash-size rehash-threshold))
  (apply #'make-instance 'bucket-hash-table initargs))

(defmethod salmagundi:hash-table-size ((hash-table bucket-hash-table))
  (svref (core hash-table) +size+))

(defmethod salmagundi:hash-table-count ((hash-table bucket-hash-table))
  (svref (core hash-table) +count+))

(defmethod salmagundi:make-hash-table-iterator ((hash-table bucket-hash-table))
  (let ((position 0)
        (core (core hash-table)))
    (lambda ()
      (loop
        (when (>= position (svref core +fill+))
          (return nil))
        (let ((entry (svref (svref core +order+) position)))
          (setf position (+ position 1))
          (when entry
            (return (values t (car entry) (cadr entry)))))))))

(declaim (inline bucket-index))
(defun bucket-index (core key)
  (let ((hash (funcall (svref core +hash+) key)))
    ;; The standard hash functions return non-negative fixnums; a user's
    ;; may return any integer.
    (if (kiln.sys:%primop :fixnump hash)
        (kiln.sys:%primop :fixnum-logand hash (- (svref core +size+) 1))
        (mod hash (svref core +size+)))))

(defun find-entry (core key bucket)
  (let ((code (svref core +test-code+)))
    (cond ((eql code 0)
           (loop for entry in bucket when (eq key (car entry)) return entry))
          ((eql code 1)
           (loop for entry in bucket when (eql key (car entry)) return entry))
          ((eql code 2)
           (loop for entry in bucket when (equal key (car entry)) return entry))
          (t
           (let ((test (svref core +test+)))
             (loop for entry in bucket when (funcall test key (car entry)) return entry))))))

(defun grow-and-rehash (hash-table core)
  ;; kiln: the size doubles, keeping it a power of two (the rehash size
  ;; is a hint, CLHS MAKE-HASH-TABLE).
  (let* ((size (svref core +size+))
         (new-size (* size 2))
         (new-data (make-array new-size :initial-element '()))
         (order (svref core +order+))
         (hash (svref core +hash+)))
    (dotimes (i (svref core +fill+))
      (let ((entry (svref order i)))
        (when entry
          (let ((h (funcall hash (car entry))))
            (push entry (svref new-data (if (kiln.sys:%primop :fixnump h)
                                            (kiln.sys:%primop :fixnum-logand h (- new-size 1))
                                            (mod h new-size))))))))
    (setf (svref core +data+) new-data
          (svref core +size+) new-size
          (svref core +limit+) (growth-limit hash-table new-size))))

(defun new-entry-index (core)
  (if (svref core +free+)
      (pop (svref core +free+))
      (let ((index (svref core +fill+))
            (order (svref core +order+)))
        (when (= index (length order))
          (let ((new (make-array (* 2 (length order)) :initial-element nil)))
            (replace new order)
            (setf (svref core +order+) new)))
        (setf (svref core +fill+) (+ index 1))
        index)))

(defun bucket-set (value key hash-table)
  (let* ((core (core hash-table))
         (index (bucket-index core key))
         (data (svref core +data+))
         (entry (find-entry core key (svref data index))))
    (cond (entry
           (setf (cadr entry) value))
          (t
           (let* ((position (new-entry-index core))
                  (entry (list* key value position)))
             (setf (svref (svref core +order+) position) entry)
             (push entry (svref data index)))
           (setf (svref core +count+) (+ (svref core +count+) 1))
           (when (> (svref core +count+) (svref core +limit+))
             (grow-and-rehash hash-table core)))))
  value)

(defun bucket-gethash (key hash-table default)
  (let* ((core (core hash-table))
         (entry (find-entry core key (svref (svref core +data+) (bucket-index core key)))))
    (if (null entry)
        (values default nil)
        (values (cadr entry) t))))

(defun bucket-remhash (key hash-table)
  (let* ((core (core hash-table))
         (index (bucket-index core key))
         (data (svref core +data+))
         (entry (find-entry core key (svref data index))))
    (when entry
      (setf (svref data index) (delete entry (svref data index) :test #'eq))
      (setf (svref (svref core +order+) (cddr entry)) nil)
      (push (cddr entry) (svref core +free+))
      (setf (svref core +count+) (- (svref core +count+) 1)))
    (not (null entry))))

(defvar *bucket-hash-table-class* (find-class 'bucket-hash-table))

(declaim (inline bucket-hash-table-p))
(defun bucket-hash-table-p (object)
  (and (kiln.sys:%primop :standard-instance-p object)
       (eq (kiln.sys:%primop :instance-class object) *bucket-hash-table-class*)))

(defmethod (setf salmagundi:gethash) (value key (hash-table bucket-hash-table) &optional default)
  (declare (ignore default))
  (bucket-set value key hash-table))

(defmethod salmagundi:gethash (key (hash-table bucket-hash-table) &optional default)
  (bucket-gethash key hash-table default))

(defmethod salmagundi:remhash (key (hash-table bucket-hash-table))
  (bucket-remhash key hash-table))

(defmethod salmagundi:clrhash ((hash-table bucket-hash-table))
  (let ((core (core hash-table)))
    (fill (svref core +data+) '())
    (fill (svref core +order+) nil)
    (setf (svref core +count+) 0
          (svref core +fill+) 0
          (svref core +free+) '()))
  hash-table)

(defmethod salmagundi:maphash (function (hash-table bucket-hash-table))
  ;; The function may set or remove the current entry (CLHS 3.6).
  (let* ((core (core hash-table))
         (order (svref core +order+)))
    (dotimes (i (svref core +fill+))
      (let ((entry (svref order i)))
        (when entry
          (funcall function (car entry) (cadr entry)))))))
