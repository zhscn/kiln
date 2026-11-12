;;; COMPILE to native code: the compiler module
;;; compiles lambda expressions into the running image (kiln_rt_jit).

(defun native-p (f)
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

;; MACROLET not at top level; the inner expander uses the outer local macro
(print (funcall (compile nil '(lambda (x)
                               (macrolet ((twice (form) `(* 2 ,form)))
                                 (macrolet ((quad (form) `(twice (twice ,form)))
                                            (const () (twice 5)))
                                   (list (twice x) (quad x) (const))))))
                7))

;; EVAL is native: a DEFMACRO takes effect before the next form of a
;; PROGN is compiled; DEFUN'd functions are native
(print (eval '(progn
               (defmacro ev-square (x) `(* ,x ,x))
               (defun ev-f (n) (ev-square (+ n 1)))
               (ev-f 3))))
(print (eq (type-of (fdefinition 'ev-f)) (type-of #'car)))
(print (eval '(eval-when (:execute) (defvar *ev-var* 41) (incf *ev-var*))))
(print (eval ''quoted))
(print (eval '*ev-var*))

;; LOAD evaluates natively too
(defvar *ld*)
(with-open-file (out "build/test/co-native-load.lisp" :direction :output :if-exists :supersede)
  (format out "(defmacro ld-twice (x) `(list ,x ,x))~%(defun ld-f (y) (ld-twice (1+ y)))~%(defparameter *ld* (ld-f 1))~%"))
(load "build/test/co-native-load.lisp")
(print (list *ld* (ld-f 10)))
