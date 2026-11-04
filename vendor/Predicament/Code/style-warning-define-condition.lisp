(cl:in-package #:predicament)

;;; kiln: a WARNING (CLHS 9.2: style-warning, warning, condition, t).
(define-condition style-warning (warning)
  ()
  ;; kiln: no report that ignores the condition: it would take precedence
  ;; over the reports of classes later in a subclass's precedence list
  ;; (Khazern's conditions are PARSE-ERRORs and ACCLIMATION:CONDITIONs).
  #-kiln
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (format stream "A style warning was signaled."))))

(setf (documentation 'style-warning 'type)
      (format nil
              "Class precedece list:~@
               style-warning, warning, condition, t~@
               ~@
               Instances of this class can be used to represent~@
               situations where some code is conforming, but still~@
               not acceptable, for instance becuase it is unidiomatic~@
               or inefficient."))
