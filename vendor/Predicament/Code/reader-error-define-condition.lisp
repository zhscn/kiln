(cl:in-package #:predicament)

(define-condition reader-error (error)
  ()
  ;; kiln: no report that ignores the condition: it would take precedence
  ;; over the reports of classes later in a subclass's precedence list
  ;; (Khazern's conditions are PARSE-ERRORs and ACCLIMATION:CONDITIONs).
  #-kiln
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (format stream
                     "An error occurred during a READ operation."))))

(setf (documentation 'reader-error 'type)
      (format nil
              "Class precedence list:~@
               reader-error, error, serious-condition, condition, t~@
               ~@
               An instance of this class can be used to represent~@
               errors signaled by READ."))
