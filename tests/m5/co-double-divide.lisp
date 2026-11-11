(defun divide-double-values (left right)
  (declare (double-float left right))
  (/ left right))
(print (divide-double-values 9d0 2d0))
(print (divide-double-values -9d0 2d0))
(print (kiln.kernel::%primop :double-float-high-bits (divide-double-values -0d0 3d0)))

(let ((function (compile nil '(lambda (left right)
                               (declare (double-float left right))
                               (* (/ (+ left 2d0) right) 3d0)))))
  (print (funcall function 2d0 2d0))
  (dolist (zero (list 0d0 -0d0))
    (print (handler-case (funcall function 2d0 zero)
             (division-by-zero (condition)
               (list (eq (arithmetic-error-operation condition) '/)
                     (arithmetic-error-operands condition))))))
  (print (handler-case (funcall function 2 2d0) (type-error () 'type-error))))

(let ((log nil))
  (print (handler-case
             (unwind-protect
                  (divide-double-values (progn (push :left log) 7d0)
                                        (progn (push :right log) -0d0))
               (push :cleanup log))
           (division-by-zero (condition)
             (list (arithmetic-error-operands condition) (reverse log))))))

(let ((value 8d0))
  (declare (double-float value))
  (print (/ (+ value 4d0)
            (progn (setq value 3d0) (kiln.sys:%gc) value))))

(let* ((nan (kiln.kernel::%primop :make-double-float-bits #x7ff80000 123))
       (result (divide-double-values 3d0 nan)))
  (print (and (kiln.kernel::non-finite-float-p result)
              (not (kiln.kernel::infinite-float-p result)))))
(print (kiln.kernel::infinite-float-p
        (divide-double-values 1d0 4.9406564584124654d-324)))

(let ((value 8d0))
  (declare (double-float value))
  (print (handler-case
             (/ (+ value 4d0) (progn (setq value 99d0) (kiln.sys:%gc) -0d0))
           (division-by-zero (condition) (arithmetic-error-operands condition)))))
