(defun mir-scoped-byte (value)
  (declare (integer value) (optimize (safety 3)))
  (locally (declare (type (unsigned-byte 8) value)) (+ value 1)))
(print (= 256 (mir-scoped-byte 255)))
(print (handler-case (progn (mir-scoped-byte -1) nil) (type-error () t)))
(print (handler-case (progn (mir-scoped-byte 256) nil) (type-error () t)))

(defun mir-scoped-empty (value)
  (declare (optimize (safety 3)))
  (locally (declare (type nil value)) value))
(print (handler-case (progn (mir-scoped-empty nil) nil) (type-error () t)))

(let* ((value 1) (writer (lambda () (setq value "changed"))))
  (funcall writer)
  (print (handler-case
             (progn (locally (declare (fixnum value)) (identity value)) nil)
           (type-error (condition) (equal (type-error-datum condition) "changed")))))

(let ((value "outside"))
  (locally (declare (fixnum value)) nil)
  (print (equal value "outside")))
