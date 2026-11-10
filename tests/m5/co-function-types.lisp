(let ((function
        (compile nil '(lambda (first second)
                        (flet ((step-value (value) (declare (fixnum value)) (+ value 1)))
                          (values (step-value first) (step-value second)))))))
  (print (multiple-value-list (funcall function 3 4)))
  (print (handler-case (funcall function 3 "bad") (type-error () 'type-error))))
(let ((function
        (compile nil '(lambda ()
                        (flet ((two-values (value) (values value (+ value 1))))
                          (list (multiple-value-list (two-values 2))
                                (multiple-value-list (two-values 3))))))))
  (print (funcall function)))
