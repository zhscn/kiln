;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(let* ((form `(locally (declare (optimize (debug 0)))
                (list ,@(loop repeat 24 collect
                          '(lambda (x) (flet ((leaf (y) (+ y 1))) (leaf x)))))))
       (forms (front-end-forms (list form)))
       (unit (hir-to-mir (toplevel-form-ast (first forms))))
       (original (symbol-function 'mir-compute-function-flow)) (solves 0))
  (unwind-protect
       (progn
         (setf (symbol-function 'mir-compute-function-flow)
               (lambda (unit) (incf solves) (funcall original unit)))
         (mir-inline-local-functions unit)
         ;; Independent callers share a target snapshot. The terminal round
         ;; has no eligible calls and needs no further function-flow solve.
         (assert (= solves 1))
         (verify-mir unit)
         (loop for function across (hir-buffer-view (mir-unit-functions unit)) do
           (assert (null (mir-inline-candidates function)))))
    (setf (symbol-function 'mir-compute-function-flow) original)))

;; A callee that is itself being expanded must be deferred to a later batch.
(let* ((form '(locally (declare (optimize (debug 0)))
                (flet ((leaf (x) (+ x 1)))
                  (flet ((middle (x) (leaf x))) (middle 4)))))
       (forms (front-end-forms (list form)))
       (unit (mir-lift-local-functions (hir-to-mir (toplevel-form-ast (first forms))))))
  (mir-inline-local-functions unit)
  (verify-mir unit))
(format t "Inlining batches independent callers and defers mutable source bodies.~%")
