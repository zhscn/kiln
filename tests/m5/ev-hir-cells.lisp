;; Returned closures share captured mutable required arguments.
(let ((f (eval '(lambda (x) (lambda () (incf x))))))
  (let ((counter (funcall f 10)))
    (print (funcall counter))
    (print (funcall counter))))
(print (handler-case
           (funcall (eval '(lambda (x) (ccase x (a 2)))) 1)
         (type-error (c) (type-error-datum c))))

;; Large frames preserve cells for parameters and local bindings beyond slot 255.
(let* ((vars (loop for i below 260 collect (gensym "ARG")))
       (last (car (last vars)))
       (f (eval `(lambda ,vars
                   (declare (ignorable ,@vars))
                   (lambda () (incf ,last)))))
       (counter (apply f (loop for i below 260 collect i))))
  (print (funcall counter))
  (print (funcall counter)))
(let* ((vars (loop for i below 260 collect (gensym "LOCAL")))
       (bindings (loop for var in vars for i from 0 collect (list var i)))
       (last (car (last vars)))
       (f (eval `(lambda ()
                   (let ,bindings
                     (declare (ignorable ,@vars))
                     (labels ((walk (n)
                                (if (zerop n) ,last (walk (1- n)))))
                       #'walk))))))
  (print (funcall (funcall f) 3)))
