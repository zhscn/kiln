(defun bounded-arithmetic (input)
  (let* ((x (logand input 255)) (y (+ x 7)))
    (list (+ y y) (- y x) (* x y) (< x y) (>= x y)
          (logxor x y) (integerp y) (consp (cons x y)))))
(print (bounded-arithmetic 250))
(print (bounded-arithmetic -1))

(defun guarded-arithmetic (x y)
  (if (typep x 'fixnum)
      (if (typep y 'fixnum)
          (list (+ x y) (- x y) (* x y) (< x y) (/= x y))
          'other)
      'other))
(print (guarded-arithmetic 7 9))
(print (guarded-arithmetic 4611686018427387903 2))
(print (guarded-arithmetic -4611686018427387904 -1))
(print (guarded-arithmetic 1 "other"))

;;; Facts about a mutable binding must not survive calls to its writer.
(let ((x 1))
  (let ((writer (lambda () (setq x "changed"))))
    (funcall writer)
    (print (integerp x))
    (print (stringp x))))

;;; Folding a predicate must still evaluate its argument and preserve errors.
(let ((count 0))
  (print (consp (progn (incf count) (cons 1 2))))
  (print count))
(print (handler-case (integerp (logand "bad" 255)) (type-error () 'type-error)))

;;; Vector knowledge does not prove an index in bounds.
(let ((v (vector 10 20 30)))
  (print (aref v 1))
  (print (handler-case (aref v 3) (error () 'bounds))))

(defun conditional-type (x)
  (if (not (typep x 'fixnum)) 'other (+ x 1)))
(print (conditional-type 41))
(print (conditional-type "other"))
