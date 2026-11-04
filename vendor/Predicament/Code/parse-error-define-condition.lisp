(cl:in-package #:predicament)

(define-condition parse-error (error)
  ()
  ;; kiln: no report that ignores the condition: it would take precedence
  ;; over the reports of classes later in a subclass's precedence list
  ;; (Khazern's conditions are PARSE-ERRORs and ACCLIMATION:CONDITIONs).
  #-kiln
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (format stream "A parse error has occurred."))))

(setf (documentation 'parse-error 'type)
      (format nil
              "Class precedence list:
               parse-error, error, serious-condition, condition, t~@
               ~@
               An instance of this condition class is signaled as~@
               a result of an error occurring during parsing."))
