(defun mir-capture-compile (body)
  (let ((kiln.compiler::*compiler-pipeline* :mir))
    (compile nil `(lambda (n) (declare (optimize (debug 0))) ,body))))

(defun mir-capture-check (body expected)
  (print (equal (funcall (mir-capture-compile body) 10) expected)))

(mir-capture-check
 '(flet ((g (x) (kiln.sys:%gc) (+ n x)))
    (flet ((f (x) (g x))) (declare (notinline f)) (f 2)))
 12)

(mir-capture-check
 '(let ((delta 7))
    (flet ((g (x) (kiln.sys:%gc) (+ n x)))
      (flet ((f (x) (+ delta (g x)))) (declare (notinline f)) (f 1))))
 18)

(mir-capture-check
 '(let ((count 0))
    (flet ((g (x) (kiln.sys:%gc) (+ n x)))
      (flet ((f (x) (incf count) (+ count (g x))))
        (declare (notinline f)) (list (f 1) (f 2) count))))
 '(12 14 2))

(mir-capture-check
 '(flet ((g (x) (kiln.sys:%gc) (+ n x)))
    (flet ((f (x &optional (y (g x) yp) &rest tail)
             (kiln.sys:%gc) (list y yp tail)))
      (declare (notinline f)) (list (f 1) (f 1 7 :a :b) (f 1 nil))))
 '((11 nil nil) (7 t (:a :b)) (nil t nil)))

(mir-capture-check
 '(flet ((g (x) (kiln.sys:%gc) (+ n x)))
    (flet ((f (&rest tail &key (x (g 1) xp)) (kiln.sys:%gc) (list x xp tail)))
      (declare (notinline f))
      (list (f) (f :x 19) (f :x nil)
            (handler-case (f :bad 2) (program-error () :bad-key)))))
 '((11 nil nil) (19 t (:x 19)) (nil t (:x nil)) :bad-key))

(mir-capture-check
 '(flet ((g (x) (kiln.sys:%gc) (+ n x)))
    (flet ((f (x &rest tail) (cons (g x) tail)))
      (declare (notinline f)) (multiple-value-call #'f (values 1) (values 2 3))))
 '(11 2 3))

(let ((function (mir-capture-compile
                 '(flet ((g (x) (kiln.sys:%gc) (+ n x)))
                    (flet ((f () #'g)) (declare (notinline f)) (funcall (f) 2))))))
  (print (and (= 12 (funcall function 10)) (= 22 (funcall function 20)))))

(let ((function (funcall (mir-capture-compile
                         '(flet ((g (x) (kiln.sys:%gc) (+ n x)))
                            (flet ((f (x) (g x))) (f 1) #'f))) 10)))
  (kiln.sys:%gc)
  (print (= 12 (funcall function 2))))

(mir-capture-check
 '(labels ((f (x) (kiln.sys:%gc) (if (zerop x) n (f (1- x))))) (f 4))
 10)

(let* ((maker (mir-capture-compile
               '(labels ((walk (left)
                           (incf n)
                           (kiln.sys:%gc)
                           (if (zerop left) n (walk (1- left)))))
                  #'walk)))
       (a (funcall maker 10))
       (b (funcall maker 100)))
  (assert (= (funcall a 2) 13))
  (assert (= (funcall b 1) 102))
  (assert (= (funcall a 0) 14)))

(let ((function (mir-capture-compile
                 '(flet ((g (x) (+ n x))) (flet ((f (x) (g x))) (f))))))
  (print (handler-case (progn (funcall function 10) nil) (program-error () t))))
