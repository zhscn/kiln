(flet ((step-value (value) (+ value 1)))
  (print (list (step-value 2) (step-value 4))))

(labels ((make-value (value) (+ value 1))
         (use-value (value) (make-value value)))
  (print (list (use-value 2) (use-value 5) (make-value 9))))

(defvar *saved-typed-function* nil)
(flet ((step-value (value) (declare (fixnum value)) (+ value 1)))
  (setq *saved-typed-function* #'step-value)
  (print (list (step-value 2) (step-value 4))))
(print (handler-case (funcall *saved-typed-function* "bad") (type-error () 'type-error)))

(defun call-with-unknown-value (value)
  (flet ((step-value (input) (declare (fixnum input)) (+ input 1)))
    (list (step-value value) (step-value 2))))
(print (call-with-unknown-value 3))
(print (handler-case (call-with-unknown-value "bad") (type-error () 'type-error)))

(flet ((two-values (value) (values value (+ value 1))))
  (print (multiple-value-list (two-values 3)))
  (print (multiple-value-list (two-values 4))))

(flet ((step-value (value) (+ value 1)))
  (print (step-value 2))
  (print (handler-case (integerp (step-value)) (program-error () 'program-error)))
  (print (step-value 4)))

(flet ((first-value (first second) (declare (ignore second)) first))
  (let ((value 3)) (print (first-value value (setq value "changed"))))
  (print (first-value 4 nil)))

(let ((functions nil))
  (dotimes (index 2)
    (let ((captured (* index 4611686018427387903)))
      (flet ((read-captured () captured))
        (print (+ (read-captured) 1))
        (push #'read-captured functions))))
  (print (mapcar #'funcall (nreverse functions))))

(labels ((even-value (n) (if (zerop n) t (odd-value (1- n))))
         (odd-value (n) (if (zerop n) nil (even-value (1- n)))))
  (print (list (even-value 10) (even-value 11))))

(flet ((large-value (ignored) (declare (ignore ignored)) (+ 4611686018427387903 1)))
  (print (integerp (large-value nil)))
  (print (+ (large-value t) 1)))
