;;; Places that are local macros or symbol macros: the standard macros see
;;; the lexical environment (vendor/README.md, Common-macros).
(defun f (v)
  (macrolet ((out (i) (declare (ignore i)) `(car v)))
    (setf (out 0) 1)
    (incf (out 0) 10)
    v))
(print (f (list 0 2)))
(defun g (v)
  (symbol-macrolet ((head (car v)))
    (push 'x head)
    v))
(print (g (list nil 2)))
