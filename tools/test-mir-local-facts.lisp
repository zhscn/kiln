;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(let* ((forms (front-end-forms '((values 1 'two))))
       (unit (hir-to-mir (toplevel-form-ast (first forms))))
       (function (mir-at (mir-unit-functions unit) 0))
       (original (symbol-function 'mir-compute-types)) (solves 0))
  (unwind-protect
       (progn
         (setf (symbol-function 'mir-compute-types)
               (lambda (&rest arguments) (incf solves) (apply original arguments)))
         (let ((types (mir-infer-types function)) (packets (mir-infer-value-facts function)))
           (assert (= solves 1))
           (multiple-value-bind (expected-types expected-packets) (funcall original function)
             (assert (equalp types expected-types))
             (assert (equalp packets expected-packets)))
           (assert (eq packets (mir-infer-value-facts function)))
           (assert (eq types (mir-infer-types function)))
           (mir-run-pass unit function #'identity)
           ;; A new revision cannot retain either half of the old solution.
           (let ((new-packets (mir-infer-value-facts function))
                 (new-types (mir-infer-types function)))
             (assert (= solves 2))
             (assert (not (eq packets new-packets)))
             (assert (not (eq types new-types))))))
    (setf (symbol-function 'mir-compute-types) original)))
(format t "Local primary and bundle facts share one solve and invalidate together.~%")
