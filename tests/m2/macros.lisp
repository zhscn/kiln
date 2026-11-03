;; User macros run at compile time; standard macros come from Common-macros.
(defmacro twice (form) (list 'progn form form))
(defmacro my-inc (var) (list 'setq var (list '+ var 1)))

(let ((x 0))
  (twice (my-inc x))
  (print x))

(defun classify (n)
  (cond ((< n 0) 'negative)
        ((= n 0) 'zero)
        (t 'positive)))
(print (classify -3))
(print (classify 0))
(print (classify 9))

(defun sum-list (l)
  (let ((s 0))
    (dolist (x l) (setq s (+ s x)))
    s))
(print (sum-list '(1 2 3 4)))

(let ((acc nil))
  (dotimes (i 4) (push i acc))
  (print acc))

(print (and 1 2 3))
(print (or nil nil 4))
(print (when (> 2 1) 'yes))
(print (unless (> 2 1) 'yes))
(print (case 3 (1 'one) ((2 3) 'two-or-three) (t 'other)))

;; Macros defined in terms of earlier functions, called at compile time.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun square-form (x) (list '* x x)))
(defmacro square (x) (square-form x))
(print (square 12))

;; Global variables.
(defvar *count* 10)
(defparameter *step* 5)
(defun bump () (setq *count* (+ *count* *step*)))
(bump)
(bump)
(print *count*)
