;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)
(let* ((forms (front-end-forms '((lambda (x) (if (identity x) 1 2)))))
       (unit (hir-to-mir (toplevel-form-ast (first forms))))
       (original (symbol-function 'mir-control-flow)) (computations 0))
  (unwind-protect
       (progn
         (setf (symbol-function 'mir-control-flow)
               (lambda (function) (incf computations) (funcall original function)))
         (verify-mir unit)
         (assert (= computations (hir-buffer-count (mir-unit-functions unit))))
         (let ((checked computations))
           (loop for function across (hir-vector (mir-unit-functions unit)) do
             (mir-block-parameter-plan function)
             (mir-reachable-blocks function)
             (mir-binding-regions function))
           (assert (= computations checked))
           (mir-run-pass unit (mir-at (mir-unit-functions unit) 1) #'identity
                         :changes '(:instructions))
           (assert (= computations checked))
           (verify-mir unit)
           (assert (= computations (* checked 2)))))
    (setf (symbol-function 'mir-control-flow) original)))
(format t "Verification computes CFG facts freshly and later analyses reuse them.~%")
