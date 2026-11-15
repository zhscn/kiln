(defun mir-flow-compile (form)
  (let ((kiln.compiler::*compiler-pipeline* :mir)) (compile nil form)))

(let ((function (mir-flow-compile
                 '(lambda ()
                    (declare (optimize (debug 0)))
                    (flet ((inc (x) (+ x 1)) (use (f x) (funcall f x)))
                      (declare (notinline inc use)) (use #'inc 41))))))
  (print (= 42 (funcall function))))

(let ((function (mir-flow-compile
                 '(lambda ()
                    (declare (optimize (debug 0)))
                    (labels ((inc (x) (+ x 1)) (give () #'inc))
                      (declare (notinline inc give)) (funcall (give) 4))))))
  (print (= 5 (funcall function))))

(let ((function (mir-flow-compile
                 '(lambda ()
                    (declare (optimize (debug 0)))
                    (labels ((maker (n) (lambda (x) (+ n x))))
                      (declare (notinline maker))
                      (let ((a (maker 10)) (b (maker 20)))
                        (kiln.sys:%gc) (list (funcall a 1) (funcall b 1) (eq a b))))))))
  (print (equal '(11 21 nil) (funcall function))))

(let ((function (mir-flow-compile
                 '(lambda ()
                    (declare (optimize (debug 0)))
                    (flet ((inc (x) (+ x 1)) (dec (x) (- x 1)) (use (f x) (funcall f x)))
                      (declare (notinline inc dec use)) (list (use #'inc 3) (use #'dec 3)))))))
  (print (equal '(4 2) (funcall function))))

(let ((function (mir-flow-compile
                 '(lambda (n)
                    (declare (optimize (debug 0)))
                    (labels ((walk (n) (if (zerop n) 1 (dispatch #'walk (1- n))))
                             (dispatch (f n) (funcall f n)))
                      (walk n))))))
  (print (= 1 (funcall function 20))))

(let ((function (mir-flow-compile
                 '(lambda ()
                    (declare (optimize (debug 0)))
                    (flet ((inc (x) (+ x 1)) (use (f x) (funcall f x)))
                      (declare (notinline inc use)) (use #'inc))))))
  (print (handler-case (progn (funcall function) nil) (program-error () t))))

(let ((function (mir-flow-compile
                 '(lambda ()
                    (declare (optimize (debug 0)))
                    (flet ((inc (x) (+ x 1)) (use (f x) (funcall f x)))
                      (declare (notinline inc use))
                      (multiple-value-call #'use (values #'inc 1)))))))
  (print (= 2 (funcall function))))

(let ((function (mir-flow-compile
                 '(lambda (bad)
                    (declare (optimize (debug 0)))
                    (flet ((inc (x) (+ x 1)) (use (f x) (funcall f x)))
                      (declare (notinline inc use))
                      (if bad (use 17 1) (use #'inc 1)))))))
  (print (and (= 2 (funcall function nil))
              (handler-case (progn (funcall function t) nil) (type-error () t)))))

(let ((function (mir-flow-compile
                 '(lambda (bad)
                    (declare (optimize (debug 0)))
                    (labels ((inc (x) (+ x 1)) (give (bad) (if bad 17 #'inc)))
                      (declare (notinline inc give)) (funcall (give bad) 1))))))
  (print (and (= 2 (funcall function nil))
              (handler-case (progn (funcall function t) nil) (type-error () t)))))

(let* ((maker (mir-flow-compile
               '(lambda ()
                  (declare (optimize (debug 0)))
                  (flet ((inc (x) (+ x 1)) (use (f x) (funcall f x)))
                    (declare (notinline use)) (use #'inc 3) #'use))))
       (use (funcall maker)))
  (kiln.sys:%gc)
  (print (and (= 2 (funcall use #'1- 3))
              (= 8 (funcall use (lambda (x) (* x 2)) 4)))))
