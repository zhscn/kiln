(cl:in-package #:parcl-low)

(defmethod unexport (client package symbol)
  (multiple-value-bind (putative-symbol status)
      (find-symbol client package (symbol-name client symbol))
    (if (and status (eq putative-symbol symbol))
        (progn (when (eq status :external)
                 (ensure-present-symbol client package symbol :internal))
               t)
        (restart-case 
            (error 'symbol-is-not-accessible
                   :package package
                   :symbol symbol)
          (continue ()
            :report
            (lambda (stream)
              (format stream "Continue"))
            (return-from unexport t))))))
