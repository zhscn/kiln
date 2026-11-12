;;; EVAL, COMPILE and LOAD at run time (the eval module):
;;; HIR closures, called from and calling compiled code.
(eval '(defun fact (n) (if (< n 2) 1 (* n (fact (- n 1))))))
(print (fact 10))
;; special variables, dynamic binding across compiled and HIR code
(defvar *depth* 0)
(defun native-depth () *depth*)
(print (eval '(let ((*depth* 5)) (list *depth* (native-depth)))))
;; closures, multiple values, catch/throw, unwind-protect, block/return-from
(print (eval '(let ((f (let ((n 0)) (lambda () (incf n))))) (funcall f) (funcall f))))
(print (multiple-value-list (eval '(floor 17 5))))
(print (eval '(catch 'done (unwind-protect (throw 'done :thrown) (print :cleanup)))))
(print (eval '(block b (dolist (x '(1 2 3 4)) (when (> x 2) (return-from b x))))))
;; tagbody/go, labels, flet, &optional/&key/&rest
(print (eval '(labels ((ev (n) (if (= n 0) t (od (1- n)))) (od (n) (if (= n 0) nil (ev (1- n))))) (list (ev 10) (od 7)))))
(print (eval '((lambda (a &optional (b 2) &rest r &key k) (list a b r k)) 1 3 :k 4)))
;; handler-case through HIR, conditions from native code
(print (eval '(handler-case (car 5) (type-error (e) (list :type-error (type-error-datum e))))))
;; CLOS through eval
(eval '(defclass point () ((x :initarg :x :accessor px) (y :initarg :y :accessor py))))
(eval '(defgeneric norm1 (p)))
(eval '(defmethod norm1 ((p point)) (+ (abs (px p)) (abs (py p)))))
(print (eval '(norm1 (make-instance 'point :x 3 :y -4))))
;; a HIR function as a value in native code, and setf of places
(let ((f (eval '(lambda (x) (* x x)))))
  (print (mapcar f '(1 2 3))))
(print (eval '(let ((l (list 1 2 3))) (setf (second l) 20) (push 0 l) (incf (car l) 5) l)))
(print (eval '(loop for i from 1 to 5 collect (* i i))))
(print (eval '(format nil "~a + ~a = ~a" 1 2 (+ 1 2))))
;; COMPILE
(print (funcall (compile nil '(lambda (n) (* n n))) 5))
(defun twice (x) (* 2 x))
(print (multiple-value-list (compile 'twice)))
(compile 'square '(lambda (x) (* x x)))
(print (square 7))
;; A call of an undefined function is reported after the form has run.
(eval '(defun calls-missing () (no-such-function-anywhere)))
;; LOAD: definitions, a macro used by the forms after it, IN-PACKAGE.
(defvar *dir* "build/test/eval-tmp/")
(ensure-directories-exist *dir*)
(with-open-file (s (merge-pathnames "l.lisp" *dir*) :direction :output :if-exists :supersede)
  (format s "(defmacro swap-pair (p) `(cons (cdr ,p) (car ,p)))~%")
  (format s "(defun loaded-f (x) (swap-pair (cons x (* x 10))))~%")
  (format s "(defvar *loaded* (loaded-f 4))~%")
  (format s "(defpackage #:loaded-pkg (:use #:cl) (:export #:hello))~%")
  (format s "(in-package #:loaded-pkg)~%")
  (format s "(defun hello () (list :hello *package*))~%"))
(print (load (merge-pathnames "l.lisp" *dir*)))
;; Defined only at run time: referred to through their symbols.
(print (list (symbol-value (quote *loaded*)) (funcall (quote loaded-f) 1) (package-name *package*)))
(print (first (funcall (find-symbol "HELLO" "LOADED-PKG"))))
;; The REPL, on a string: values, *, an error that returns to the prompt.
(with-input-from-string (in "(+ 1 2) (list * *) (values 1 2) (car 'x) (* 6 7)")
  (kiln.sys:repl :input in))
(print (eval '(let ((v (list 0 1))) (setf (the fixnum (car v)) 5) (incf (the fixnum (cadr v)) 2) v)))
