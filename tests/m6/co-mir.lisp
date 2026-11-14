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
