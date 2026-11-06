;;; COMPILE to native code (docs/11 §11, M5.5): the compiler module
;;; compiles lambda expressions into the running image (kiln_rt_jit).

(defun native-p (f)
  ;; Maclina's bytecode functions are funcallable instances.
  (not (typep f 'standard-object)))

(let ((f (compile nil '(lambda (x) (* x x)))))
  (print (list (native-p f) (funcall f 7) (mapcar f '(1 2 3)))))

;; literals keep their identity; uninterned symbols, strings, lists,
;; bignums, floats and ratios
(let* ((cell (list 1 2 3))
       (g (make-symbol "G"))
       (f (compile nil `(lambda () (list ',cell ',g "str" 123456789012345678901234567890
                                        1.5d0 2/3 #\a 1.5)))))
  (let ((values (funcall f)))
    (print (list (eq (first values) cell) (eq (second values) g) (cddr values)))))

;; calling image functions, special variables, dynamic binding
(defvar *depth* 0)
(defun native-depth () *depth*)
(print (funcall (compile nil '(lambda () (let ((*depth* 5)) (list *depth* (native-depth)))))))
(funcall (compile nil '(lambda () (setq *depth* 42))))
(print *depth*)

;; closures, non-local exits, conditions and unwinding through native code
(let ((counter (funcall (compile nil '(lambda () (let ((n 0)) (lambda () (incf n))))))))
  (funcall counter)
  (print (funcall counter)))
(print (funcall (compile nil '(lambda () (catch 'done (unwind-protect (throw 'done :thrown) (print :cleanup)))))))
(print (funcall (compile nil '(lambda () (handler-case (car 5) (type-error (e) (list :type-error (type-error-datum e))))))))
(print (handler-case (funcall (compile nil '(lambda (x) (error "bad ~A" x))) 3)
         (error (e) (princ-to-string e))))
(print (funcall (compile nil '(lambda (&optional (a 1) &rest r &key k) (list a r k))) 2 :k 3))
(print (funcall (compile nil '(lambda () (loop for i from 1 to 5 collect (* i i))))))

;; COMPILE with a name defines the function; undefined functions are
;; called through their symbol, so a later definition is seen
(compile 'square '(lambda (x) (* x x)))
(print (square 12))
(defun later-caller () (funcall (compile nil '(lambda () (defined-later 5)))))
(defun defined-later (x) (+ x 1))
(print (later-caller))
(print (fboundp 'never-defined-function))
(print (funcall (compile nil '(lambda () (fboundp 'never-defined-function)))))

;; CLOS from native code; generic functions dispatch on compiled methods
(defclass point () ((x :initarg :x :accessor px) (y :initarg :y :accessor py)))
(print (funcall (compile nil '(lambda () (let ((p (make-instance 'point :x 3 :y -4)))
                                          (+ (abs (px p)) (abs (py p))))))))

;; the code survives garbage collection, and so do its literals
(let ((f (compile nil '(lambda () (list "kept" '(a b c))))))
  (dotimes (i 200000) (make-list 10))
  (print (funcall f)))
(print (loop repeat 50 collect (funcall (compile nil '(lambda (x) (1+ x))) 1) into l
             finally (return (reduce #'+ l))))
