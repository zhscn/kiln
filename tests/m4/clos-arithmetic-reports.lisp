(dolist (type '(arithmetic-error division-by-zero floating-point-inexact
                floating-point-invalid-operation floating-point-overflow
                floating-point-underflow))
  (let ((condition (make-condition type)))
    (print (null (arithmetic-error-operation condition)))
    (print (zerop (search "arithmetic error" (format nil "~A" condition))))))
(let ((condition (make-condition 'arithmetic-error :operation '+ :operands '(1 2))))
  (print (not (null (search "Operation was (+ 1 2)." (format nil "~A" condition))))))
