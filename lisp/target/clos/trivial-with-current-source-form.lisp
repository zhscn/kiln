;;;; kiln has no source forms to report in conditions yet.

(in-package #:trivial-with-current-source-form)

(defmacro with-current-source-form ((form &rest forms) &body body)
  (declare (ignore form forms))
  `(progn ,@body))
