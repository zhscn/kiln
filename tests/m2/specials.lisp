;; Dynamic binding of special variables (TLS indexes, C1).
(defvar *x* 1)
(defvar *y*)

(defun get-x () *x*)
(defun set-x (v) (setq *x* v))

(print (get-x))
(let ((*x* 2))
  (print (get-x))
  (let ((*x* 3))
    (print (get-x)))
  (print (get-x)))
(print (get-x))

;; SETQ inside a binding changes the binding, not the global value.
(let ((*x* 10))
  (set-x 11)
  (print (get-x)))
(print (get-x))

;; Unwinding restores bindings: THROW, non-local RETURN-FROM, local exits.
(catch 'out
  (let ((*x* 20))
    (throw 'out nil)))
(print (get-x))

(defun call (f) (funcall f))
(block b
  (let ((*x* 30))
    (call (lambda () (return-from b nil)))))
(print (get-x))

(block b
  (let ((*x* 40))
    (return-from b nil)))
(print (get-x))

(tagbody
   (let ((*x* 45))
     (go done))
 done)
(print (get-x))

;; Closures do not capture special bindings.
(defun make-reader () (lambda () *x*))
(let ((f (let ((*x* 50)) (make-reader))))
  (print (funcall f))
  (let ((*x* 51))
    (print (funcall f))))

;; Binding an unbound variable, and its value surviving GCs.
(print (boundp '*y*))
(let ((*y* (list 1 2 3)))
  (print (boundp '*y*))
  (%gc)
  (print (symbol-value '*y*)))
(print (boundp '*y*))

;; Bindings are restored when an unwind crosses stacks.
(catch 'k
  (let ((*x* 60))
    (%call-on-new-stack
     (lambda (v)
       (let ((*x* v))
         (print (get-x))
         (throw 'k nil)))
     61)))
(print (get-x))

;; A binding made during an unwind-protect cleanup.
(catch 'k
  (unwind-protect (throw 'k nil)
    (let ((*x* 70)) (print (get-x)))))
(print (get-x))
