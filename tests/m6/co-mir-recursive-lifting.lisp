(defun mir-recursive-compile (body)
  (let ((kiln.compiler::*compiler-pipeline* :mir))
    (compile nil `(lambda (n) (declare (optimize (debug 0))) ,body))))

(defun mir-recursive-check (body expected)
  (print (equal (funcall (mir-recursive-compile body) 10) expected)))

(mir-recursive-check
 '(labels ((f (x) (kiln.sys:%gc) (if (zerop x) n (f (1- x))))) (f 3))
 10)

(mir-recursive-check
 '(labels ((f (x) (kiln.sys:%gc) (if (zerop x) n (g (1- x))))
           (g (x) (kiln.sys:%gc) (f x))) (f 3))
 10)

(mir-recursive-check
 '(let ((count 0))
    (labels ((f (x) (incf count) (kiln.sys:%gc) (if (zerop x) (+ n count) (f (1- x))))) (f 3)))
 14)

(mir-recursive-check
 '(labels ((f (x &optional (y n yp))
             (kiln.sys:%gc) (if (zerop x) (list y yp) (f (1- x) (1+ y))))) (f 3))
 '(13 t))

(mir-recursive-check
 '(labels ((f (x &rest tail)
             (kiln.sys:%gc) (if (zerop x) (list n (car tail) (length tail)) (f (1- x) (car tail)))))
    (f 3 :a))
 '(10 :a 1))

(mir-recursive-check
 '(labels ((f (x &key (y n))
             (kiln.sys:%gc) (if (zerop x) y (f (1- x) :y (1+ y))))) (f 3))
 13)

(mir-recursive-check
 '(let ((count 0))
    (labels ((f (x) (incf count) (kiln.sys:%gc) (if (zerop x) (+ n count) (g (1- x))))
             (g (x) (incf count) (kiln.sys:%gc) (f x))) (f 3)))
 17)

(mir-recursive-check
 '(let ((base (+ n 1)))
    (labels ((f (x) (kiln.sys:%gc) (if (zerop x) base (f (1- x))))) (f 3)))
 11)

(mir-recursive-check
 '(let ((count 0))
    (labels ((f (x) (incf count) (kiln.sys:%gc)
               (if (zerop x) (+ n count) (multiple-value-call #'f (values (1- x)))))) (f 3)))
 14)

(let ((function (mir-recursive-compile
                 '(labels ((f (x) (kiln.sys:%gc) (if (zerop x) n (f (1- x))))) (f 3)))))
  (print (equal (list (funcall function 10) (funcall function 20)) '(10 20))))

(let ((function (funcall (mir-recursive-compile
                         '(labels ((f (x) (kiln.sys:%gc) (if (zerop x) n (g (1- x))))
                                   (g (x) (kiln.sys:%gc) (f x)))
                            (f 3) #'g)) 10)))
  (kiln.sys:%gc)
  (print (= 10 (funcall function 3))))

(mir-recursive-check
 '(labels ((f (x) (if (zerop x) n (f (1- x)))))
    (handler-case (f) (program-error () :bad-arity)))
 :bad-arity)

(mir-recursive-check
 '(labels ((f (x) (kiln.sys:%gc) (if (zerop x) n (f (1- x)))))
    (multiple-value-call #'f (values-list (list 3))))
 10)

(mir-recursive-check
 '(labels ((f (x &key (y n)) (if (zerop x) y (f (1- x) :y (1+ y)))))
    (handler-case (f 0 :bad 1) (program-error () :bad-key)))
 :bad-key)

(mir-recursive-check
 '(let ((count 0))
    (labels ((f (x) (incf count) (kiln.sys:%gc) (if (zerop x) (+ n count) (f (1- x)))))
      (kiln.kernel::%primop :tail-funcall #'f 3)))
 14)
