(cl:in-package #:predicament)

(define-condition warning (condition)
  ()
  ;; kiln: no report that ignores the condition: it would take precedence
  ;; over the reports of classes later in a subclass's precedence list
  ;; (Khazern's conditions are PARSE-ERRORs and ACCLIMATION:CONDITIONs).
  #-kiln
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (format stream
                     "A warning was signaled."))))

(setf (documentation 'warning 'type)
      (format nil
              "Class precedece list:~@
               warning, condition, t~@
               ~@
               This class is the superclass of all types of warnings"))
