(defun mir-region-check (body expected)
  (let* ((kiln.compiler::*compiler-pipeline* :mir)
         (function (compile nil `(lambda (n) (declare (optimize (debug 0))) ,body))))
    (print (equal (funcall function 10) expected))))

(mir-region-check
 '(flet ((f (x)
           (let ((*inline-region-value* x))
             (declare (special *inline-region-value*))
             (kiln.sys:%gc) *inline-region-value*)))
    (let ((*inline-region-value* :outer))
      (declare (special *inline-region-value*))
      (list (f n) (f 2) *inline-region-value*)))
 '(10 2 :outer))

(mir-region-check
 '(flet ((f (x)
           (progv '(inline-progv-value) (list x)
             (kiln.sys:%gc) (symbol-value 'inline-progv-value))))
    (list (f n) (f 2)))
 '(10 2))

(mir-region-check
 '(flet ((f (x) (catch 'done (kiln.sys:%gc) (throw 'done (values x 2)))))
    (list (multiple-value-list (f n)) (multiple-value-list (f 3))))
 '((10 2) (3 2)))

(mir-region-check
 '(let ((log nil))
    (flet ((f (x) (unwind-protect (values x 2) (kiln.sys:%gc) (push x log))))
      (list (multiple-value-list (f n)) (multiple-value-list (f 3)) log)))
 '((10 2) (3 2) (3 10)))

(mir-region-check
 '(let ((log nil))
    (flet ((f (x) (unwind-protect (throw 'out (values x 2)) (kiln.sys:%gc) (push x log))))
      (list (multiple-value-list (catch 'out (f n))) log)))
 '((10 2) (10)))

(mir-region-check
 '(flet ((f (x)
           (block out (flet ((g () (kiln.sys:%gc) (return-from out x))) (g)))))
    (list (f n) (f 3)))
 '(10 3))

(mir-region-check
 '(let ((log nil))
    (let ((*inline-region-value* :outer))
      (declare (special *inline-region-value*))
      (flet ((f (x)
               (let ((*inline-region-value* x))
                 (declare (special *inline-region-value*))
                 (unwind-protect (throw 'out x)
                   (kiln.sys:%gc) (push *inline-region-value* log)))))
        (list (catch 'out (f n)) *inline-region-value* log))))
 '(10 :outer (10)))

(mir-region-check
 '(flet ((f (x) (catch 'done (unwind-protect (throw 'done x) (kiln.sys:%gc)))))
    (catch 'done (list (f n) (f 11))))
 '(10 11))

(mir-region-check
 '(flet ((f (x) (kiln.kernel::%primop :tail-funcall #'identity x)))
    (let ((*inline-region-value* n))
      (declare (special *inline-region-value*))
      (+ 1 (f *inline-region-value*))))
 11)

(mir-region-check
 '(flet ((f (x) (kiln.kernel::%primop :tail-funcall-function #'identity x)))
    (let ((*inline-region-value* n))
      (declare (special *inline-region-value*))
      (+ 1 (f *inline-region-value*))))
 11)

(mir-region-check
 '(flet ((f (x) (kiln.kernel::%primop :tail-funcall #'values x 2)))
    (unwind-protect (multiple-value-list (f n)) (kiln.sys:%gc)))
 '(10 2))

(mir-region-check
 '(flet ((f (x) (kiln.kernel::%primop :tail-funcall x n)))
    (handler-case (f 'identity) (type-error () :not-a-function)))
 :not-a-function)

(mir-region-check
 '(flet ((f (*inline-region-value* &optional (y (progn (kiln.sys:%gc) (+ *inline-region-value* 1))))
           (declare (special *inline-region-value*)) (list *inline-region-value* y)))
    (let ((*inline-region-value* :outer))
      (declare (special *inline-region-value*))
      (list (f n) (f 2 nil) *inline-region-value*)))
 '((10 11) (2 nil) :outer))
