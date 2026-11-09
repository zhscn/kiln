(cl:in-package #:predicament)

(define-condition floating-point-overflow (arithmetic-error)
  ())

(setf (documentation 'floating-point-overflow 'type)
      (format nil
              "Class precedence list:
               floating-point-overflow, arithmetic-error, error, serious-condition, condition, t~@
               ~@
               An instance of this condition is signaled as a result~@
               of an overflow of a floating-point operation."))
