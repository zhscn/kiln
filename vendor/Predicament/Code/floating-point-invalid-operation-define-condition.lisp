(cl:in-package #:predicament)

(define-condition floating-point-invalid-operation (arithmetic-error)
  ())

(setf (documentation 'floating-point-invalid-operation 'type)
      (format nil
              "Class precedence list:~@
               floating-point-invalid-operation, arithmetic-error, error, serious-condition, condition, t~@
               ~@
               An instance of this condition class can be signaled~@
               as a result of certain floating-point traps.  However~@
               it is implementation-dependent whether floating-point~@
               traps occur.  As a result, conforming programs can not~@
               rely on this condition being signaled."))
