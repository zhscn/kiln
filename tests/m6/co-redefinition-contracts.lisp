(eval '(defmacro replaced (x) `(+ ,x 1)))
(eval '(defun uses-replaced () (replaced 10)))
(print (uses-replaced))
(eval '(defun replaced (x) (* x 2)))
(print (null (macro-function 'replaced)))
(print (uses-replaced))
(print (funcall (compile nil '(lambda () (replaced 7)))))

;; A consumer can precede the macro it will need during a cyclic update.
(eval '(defmacro root-value () 1))
(eval '(defun early-consumer () (root-value)))
(eval '(defmacro pending-value () (root-value)))
(eval '(defun early-consumer () (list (root-value) (pending-value))))
(eval '(defmacro root-value () 9))
(print (early-consumer))

;; An earlier consumer can be selected before a mutually dependent macro
;; group. Its expansion must agree with the definitions the update leaves.
(handler-bind ((style-warning #'muffle-warning))
  (eval '(defun first-cycle-consumer () (list (cycle-left) (cycle-right)))))
(eval '(defmacro cycle-left () 1))
(eval '(defmacro cycle-right () (cycle-left)))
(eval '(defmacro cycle-left () (+ (cycle-right) 1)))
(print (equal (first-cycle-consumer)
              (list (macroexpand '(cycle-left)) (macroexpand '(cycle-right)))))
