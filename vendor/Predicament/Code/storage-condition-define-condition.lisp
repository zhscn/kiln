(cl:in-package #:predicament)

(define-condition storage-condition (serious-condition)
  ()
  ;; kiln: no report that ignores the condition: it would take precedence
  ;; over the reports of classes later in a subclass's precedence list
  ;; (Khazern's conditions are PARSE-ERRORs and ACCLIMATION:CONDITIONs).
  #-kiln
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (format stream
                     "An error related to memory management has occurred."))))

(setf (documentation 'storage-condition 'type)
      (format nil
              "Class precedence list:~@
               storage-condition, serious-condition, condition, t~@
               ~@
               An instance of this class can be used to signal a~@
               problem with memory management, mainly dues to limits~@
               of the implementation, such as stack overflow and heap~@
               exhaustion.~@
               ~@
               An instance of this class can be signaled by an operator~@
               that implicitly creates objects, which is why such an~@
               instance can be signaled at any time"))
