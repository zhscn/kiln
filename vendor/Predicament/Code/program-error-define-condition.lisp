(cl:in-package #:predicament)

(define-condition program-error (error)
  ()
  ;; kiln: no report that ignores the condition: it would take precedence
  ;; over the reports of classes later in a subclass's precedence list
  ;; (Khazern's conditions are PARSE-ERRORs and ACCLIMATION:CONDITIONs).
  #-kiln
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (format stream
                     "Incorrect program syntax was detected."))))

(setf (documentation 'program-error 'type)
      (format nil
              "Class precedence-list:~@
               program-error, error, serious-condition, condition, t~@
               ~@
               An instance of this class can be used to represent errors~@
               resulting from incorrect program syntax, both at compile~@
               time and at run time."))
