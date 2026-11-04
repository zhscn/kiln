(cl:in-package #:predicament)

(defmethod warn ((datum warning) &rest arguments)
  (declare (ignore arguments))
  (with-simple-restart (muffle-warning "Muffle warning.")
    (signal datum)
    (format *error-output* "~&;; Warning:~%~A~%" datum))
  nil)

;;; kiln: no NIL argument in the recursive calls, as for SIGNAL.
(defmethod warn :around ((datum string) &rest arguments)
  (warn (make-condition 'simple-warning
                         :format-control datum
                         :format-arguments arguments)))

(defmethod warn :around ((datum symbol) &rest arguments)
  (warn (apply #'make-condition datum arguments)))

(defmethod warn :before ((datum warning) &rest arguments)
  (unless (null arguments)
    (error 'type-error
           :datum arguments
           :expected-type 'null)))
