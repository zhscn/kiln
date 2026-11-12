;;;; HIR execution in a fresh image compilation environment.

(in-package #:kiln.compiler)

(defun interpret-form (form)
  (let ((session (make-session)) (result nil))
    (handler-bind ((undefined-function-warning
                     (lambda (condition)
                       (when (kiln.kernel::note-compilation-unit-functions
                              (undefined-function-names condition))
                         (muffle-warning condition)))))
      (call-with-front-end
       session
       (lambda ()
         (setf result (multiple-value-list (hir-eval form *environment*))))))
    (values-list result)))
