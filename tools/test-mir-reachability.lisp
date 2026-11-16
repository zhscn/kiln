;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(dolist (form '((if (identity t) 1 2)
                (let ((x 0)) (tagbody loop (incf x) (when (< x 3) (go loop))) x)
                (block out (return-from out 1) (identity 2))
                (unwind-protect (identity 1) (identity 2))))
  (let* ((forms (front-end-forms (list form)))
         (unit (hir-to-mir (toplevel-form-ast (first forms)))))
    (loop for function across (hir-vector (mir-unit-functions unit))
          do (assert (= (mir-control-flow function) (mir-reachable-blocks function))))))
(format t "Reachability agrees with CFG verification across branches, loops and exits.~%")
