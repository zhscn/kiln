(cl:in-package #:predicament)

(define-condition floating-point-underflow (arithmetic-error)
  ())

(setf (documentation 'floating-point-underflow 'type)
      (format nil
              "Class precedence list:
               floating-point-underflow, arithmetic-error, error, serious-condition, condition, t~@
               ~@
               An instance of this condition is signaled as a result~@
               of an underflow of a floating-point operation."))
