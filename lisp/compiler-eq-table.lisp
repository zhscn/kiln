(in-package #:kiln.compiler)

#+kiln
(defstruct (compiler-eq-table (:constructor make-compiler-eq-table ()))
  (capacity 8 :type fixnum)
  (count 0 :type fixnum)
  (slots (make-array 24 :initial-element nil) :type simple-vector))

#+kiln
(defmacro with-compiler-eq-probe ((slots capacity key hash slot stored) &body body)
  ;; Match the cached hash before touching a key.
  (let ((mask (gensym "MASK")))
    `(let* ((,mask (kiln.sys:%primop :fixnum+ ,capacity -1))
            (,slot (kiln.sys:%primop :fixnum-logand ,hash ,mask)))
       (loop for ,stored = (kiln.sys:%primop :svref-unchecked ,slots ,slot)
             when (or (null ,stored)
                      (and (eql ,stored ,hash)
                           (eq ,key (kiln.sys:%primop :svref-unchecked ,slots
                                      (kiln.sys:%primop :fixnum+ ,capacity
                                       (kiln.sys:%primop :fixnum-shift-left ,slot 1))))))
               do (return (progn ,@body))
             do (setf ,slot (kiln.sys:%primop :fixnum-logand
                             (kiln.sys:%primop :fixnum+ ,slot 1) ,mask))))))

#+kiln
(defun compiler-eq-slot (slots capacity key hash)
  (declare (optimize (debug 0)))
  (with-compiler-eq-probe (slots capacity key hash slot stored) slot))

#+kiln
(defun grow-compiler-eq-table (table)
  (let* ((old-capacity (compiler-eq-table-capacity table))
         (old-slots (compiler-eq-table-slots table))
         (capacity (* 2 old-capacity))
         (slots (make-array (* 3 capacity) :initial-element nil)))
    (dotimes (old-slot old-capacity)
      (let ((hash (svref old-slots old-slot)))
        (when hash
          (let* ((old-entry (+ old-capacity (* 2 old-slot)))
                 (key (svref old-slots old-entry))
                 (slot (compiler-eq-slot slots capacity key hash))
                 (entry (+ capacity (* 2 slot))))
            (setf (svref slots slot) hash
                  (svref slots entry) key
                  (svref slots (1+ entry)) (svref old-slots (1+ old-entry)))))))
    (setf (compiler-eq-table-slots table) slots
          (compiler-eq-table-capacity table) capacity)))

#+kiln
(defun compiler-eq-ref (table key)
  (declare (optimize (debug 0)))
  (let* ((slots (compiler-eq-table-slots table))
         (capacity (compiler-eq-table-capacity table))
         (hash (kiln.sys:%primop :identity-hash key)))
    (with-compiler-eq-probe (slots capacity key hash slot stored)
      (if stored
          (values (kiln.sys:%primop :svref-unchecked slots
                    (kiln.sys:%primop :fixnum+ (kiln.sys:%primop :fixnum+ capacity 1)
                      (kiln.sys:%primop :fixnum-shift-left slot 1))) t)
          (values nil nil)))))

#+kiln
(defun (setf compiler-eq-ref) (value table key)
  (let* ((hash (kiln.sys:%primop :identity-hash key))
         (slots (compiler-eq-table-slots table))
         (capacity (compiler-eq-table-capacity table))
         (slot (compiler-eq-slot slots capacity key hash)))
    (unless (svref slots slot)
      (when (= (compiler-eq-table-count table) (ash capacity -1))
        (grow-compiler-eq-table table)
        (setf slots (compiler-eq-table-slots table)
              capacity (compiler-eq-table-capacity table)
              slot (compiler-eq-slot slots capacity key hash)))
      (setf (svref slots slot) hash
            (svref slots (+ capacity (* 2 slot))) key)
      (incf (compiler-eq-table-count table)))
    (setf (svref slots (+ capacity (* 2 slot) 1)) value)))

#-kiln
(defun make-compiler-eq-table ()
  (make-hash-table :test 'eq))

#-kiln
(defun compiler-eq-ref (table key)
  (gethash key table))

#-kiln
(defun (setf compiler-eq-ref) (value table key)
  (setf (gethash key table) value))
