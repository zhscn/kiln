;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:cl-user)
(let ((function #'identity)) (assert (eq function (kiln.lir:require-init function :test))))
(let ((condition (handler-case
                     (kiln.lir:require-init (vector kiln.kir::+packet-diagnostic-version+
                                                   kiln.kir::+packet-diagnostic-stage-program+ 1
                                                   #x3bb #x1f642) :compile-program)
                   (kiln.lir:backend-error (condition) condition))))
  (assert (eq :program (kiln.lir:backend-error-stage condition)))
  (assert (eq :compile-program (kiln.lir:backend-error-operation condition)))
  (assert (kiln.lir:backend-error-truncated-p condition))
  (assert (equal "λ🙂" (kiln.lir:backend-error-message condition))))
(dolist (result '(nil #() #(99 1 0) #(1 99 0) #(1 1 2) #(1 1 0 -1) #(1 1 0 55296)))
  (let ((condition (handler-case (kiln.lir:require-init result :test)
                     (kiln.lir:backend-error (condition) condition))))
    (assert (eq :protocol (kiln.lir:backend-error-stage condition)))))
(format t "Backend results preserve structured Unicode diagnostics and reject malformed carriers.~%")
