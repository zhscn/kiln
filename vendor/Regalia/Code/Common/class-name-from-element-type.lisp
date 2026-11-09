(cl:in-package #:regalia)

(defun non-vector-class-name-from-element-type (element-type environment)
  (let* ((upgraded (upgraded-array-element-type element-type environment))
         (entry (find upgraded *element-types* :key #'cdr :test #'equal)))
    (if entry (car entry) 'array-t)))

(defun vector-class-name-from-element-type (element-type environment)
  (let ((name (non-vector-class-name-from-element-type element-type environment)))
    (case name
      (array-t 'simple-vector)
      (array-bit 'bit-vector)
      (array-character 'string)
      (t (intern (concatenate 'cl:string "VECTOR-" (subseq (symbol-name name) 6))
                 '#:regalia)))))
