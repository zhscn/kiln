(cl:in-package #:predicament)

(defun cerror (continue-format-control datum &rest arguments)
  (let ((condition (coerce-to-condition datum
                                        (if (typep datum 'condition) nil arguments)
                                        'simple-error 'cerror)))
    (restart-case (error condition)
      (continue ()
        :report (lambda (stream) (apply #'format stream continue-format-control arguments))
        nil))))


(setf (documentation 'cerror 'function)
      (format nil
              "Syntax: cerror continue-format-control datum &rest arguments~@
               ~@
               This function invokes ERROR on on the condition designated~@
               by DATUM.  If the condition is not handled, the debugger~@
               is invoked.  During the signaling process, and while the~@
               debugger is invoked, execution can continue by the use~@
               of the CONTINUE restart.~@
               ~@
               CONTINUE-FORMAT-CONTROL is a format control used to~@
               show the associated CONTINUE restart.  ARGUMENTS are~@
               used both as arguments to FORMAT for CONTINUE-FORMAT-CONTROL~@
               and as arguments to ERROR when DATUM is a format control.~@
               ~@
               If DATUM is a condition object, ARGUMENTS can still be~@
               supplied, but are then used only in conjunction with the~@
               CONTINUE-FORMAT-CONTROL."))
