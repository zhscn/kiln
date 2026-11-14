(defun mir-test-compile (form)
  (let ((kiln.compiler::*compiler-pipeline* :mir)) (compile nil form)))

(let ((function (mir-test-compile
                 '(lambda (x y)
                    (let ((a x) (b y) (n 0))
                      (tagbody
                       again
                         (if (= n 3) (go done))
                         (let ((temp a)) (setq a b b temp))
                         (setq n (1+ n))
                         (go again)
                       done)
                      (values a b n))))))
  (print (multiple-value-list (funcall function 11 22)))
  (print (handler-case (progn (funcall function 1) :bad) (program-error () :arity))))
(let ((function (mir-test-compile
                 '(lambda (x)
                    (block done
                      (if x (return-from done (values 4 5)) (values)))))))
  (print (multiple-value-list (funcall function t)))
  (print (multiple-value-list (funcall function nil))))
(let ((function (mir-test-compile
                 '(lambda () (multiple-value-prog1 (values 6 7 8) (identity 99))))))
  (print (multiple-value-list (funcall function))))
(let ((function (mir-test-compile '(lambda (x) (declare (type fixnum x)) x))))
  (print (funcall function 12))
  (print (handler-case (progn (funcall function 'wrong) :bad) (type-error () :type))))
(let ((function (mir-test-compile
                 '(lambda (f) (funcall f 21)))))
  (print (funcall function #'1+)))
(print (handler-case (progn (mir-test-compile '(lambda () (catch 'tag (throw 'tag 3)))) :bad)
         (kiln.compiler::mir-unsupported () :unsupported)))
(defun mir-kept-definition () 17)
(handler-case
    (let ((kiln.compiler::*compiler-pipeline* :mir))
      (compile 'mir-kept-definition '(lambda () (unwind-protect 99 (identity 1)))))
  (kiln.compiler::mir-unsupported () nil))
(print (mir-kept-definition))
(let ((function (mir-test-compile
                 '(lambda (p) (the fixnum (if p 1 2))))))
  (print (list (funcall function t) (funcall function nil))))
(let ((function (mir-test-compile
                 '(lambda (p) (the fixnum (if p 1 'wrong))))))
  (print (funcall function t))
  (print (handler-case (progn (funcall function nil) :bad) (type-error () :type))))
(let ((function (mir-test-compile
                 '(lambda (p) (the (integer 5 6) (+ (if p 2 3) 3))))))
  (print (list (funcall function t) (funcall function nil))))
(let ((function (mir-test-compile
                 '(lambda () (the fixnum (+ 4611686018427387903 1))))))
  (print (handler-case (progn (funcall function) :bad) (type-error () :overflow))))
(let ((function (mir-test-compile
                 '(lambda ()
                    (let ((x 0))
                      (tagbody again (setq x (1+ x)) (if (< x 10) (go again)))
                      (the fixnum x))))))
  (print (funcall function)))
(let ((function (mir-test-compile '(lambda () (the fixnum (values))))))
  (print (handler-case (progn (funcall function) :bad) (type-error () :zero-values))))
(let ((function (mir-test-compile
                 '(lambda (x) (the integer (the fixnum (values x 20 30)))))))
  (print (multiple-value-list (funcall function 10)))
  (print (handler-case (progn (funcall function 'wrong) :bad) (type-error () :checked-values))))
(let ((function (mir-test-compile
                 '(lambda (f) (the null (funcall f))))))
  (print (multiple-value-list (funcall function (lambda () (values))))))
(let ((function (mir-test-compile
                 '(lambda (x) (declare (type fixnum x)) (the integer (+ x 1))))))
  (print (funcall function 20)))
(let ((function (mir-test-compile
                 '(lambda (x) (if (integerp x) (the integer x) (the integer x))))))
  (print (funcall function 7))
  (print (handler-case (progn (funcall function 'wrong) :bad) (type-error () :edge-type))))
(let ((function (mir-test-compile
                 '(lambda (x)
                    (if (integerp x) (progn (setq x 'changed) (the integer x)) nil)))))
  (print (handler-case (progn (funcall function 7) :bad) (type-error () :edge-assignment))))
(let ((function (mir-test-compile
                 '(lambda (x)
                    (declare (type fixnum x))
                    (if (< x 10) (the (integer -4611686018427387904 9) x)
                        (the (integer 10 4611686018427387903) x))))))
  (print (list (funcall function 9) (funcall function 10))))
(let ((function (mir-test-compile
                 '(lambda (n)
                    (declare (optimize (speed 0)))
                    (labels ((f (n) (if (zerop n) (values 7 8) (g (1- n))))
                             (g (n) (if (zerop n) (values 7 8) (f (1- n)))))
                      (the integer (f n)))))))
  (print (multiple-value-list (funcall function 10))))
(let ((function (mir-test-compile
                 '(lambda (p)
                    (declare (optimize (speed 0)))
                    (let* ((f (lambda () 7)) (g (if p f f)))
                      (the integer (funcall g)))))))
  (print (list (funcall function t) (funcall function nil))))
(let ((function (mir-test-compile
                 '(lambda (p)
                    (declare (optimize (speed 0)))
                    (let ((f (if p (lambda () 7) (lambda () 'wrong))))
                      (the integer (funcall f)))))))
  (print (funcall function t))
  (print (handler-case (progn (funcall function nil) :bad) (type-error () :call-join))))
(let ((function (mir-test-compile
                 '(lambda ()
                    (declare (optimize (speed 0)))
                    (flet ((f () (values))) (the null (f)))))))
  (print (multiple-value-list (funcall function))))
(let ((function (mir-test-compile
                 '(lambda ()
                    (declare (optimize (speed 0)))
                    (flet ((f (x) (declare (ignore x)) 7)) (the integer (f)))))))
  (print (handler-case (progn (funcall function) :bad) (program-error () :call-arity))))
(defun mir-global-source () 7)
(let ((function (mir-test-compile '(lambda () (the integer (mir-global-source))))))
  (setf (symbol-function 'mir-global-source) (lambda () 'wrong))
  (print (handler-case (progn (funcall function) :bad) (type-error () :global-call))))
(let ((function (mir-test-compile
                 '(lambda ()
                    (declare (optimize (speed 0)))
                    (flet ((f (x) (the fixnum x)))
                      (list (f 2) (f 4)))))))
  (print (funcall function)))
(let ((function (mir-test-compile
                 '(lambda ()
                    (declare (optimize (speed 0)))
                    (flet ((f (x) (the fixnum x)))
                      (f 2) (f 'wrong))))))
  (print (handler-case (progn (funcall function) :bad) (type-error () :input-join))))
(let ((function (mir-test-compile
                 '(lambda ()
                    (declare (optimize (speed 0)))
                    (flet ((f (x) (the fixnum x)))
                      (values (f 2) #'f))))))
  (let ((escaped (nth-value 1 (funcall function))))
    (print (handler-case (progn (funcall escaped 'wrong) :bad) (type-error () :escaped-input)))))
