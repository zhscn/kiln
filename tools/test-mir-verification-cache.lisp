;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(let* ((forms (front-end-forms
                '((let ((x (identity 1)))
                    (flet ((f (y) (+ x y))) (mapcar #'f '(1 2)))))))
       (unit (hir-to-mir (toplevel-form-ast (first forms))))
       (original (symbol-function 'mir-compute-function-identities))
       (counts (make-hash-table :test 'eq)))
  (unwind-protect
       (progn
         (setf (symbol-function 'mir-compute-function-identities)
               (lambda (function &rest arguments)
                 (incf (gethash function counts 0))
                 (apply original function arguments)))
         (dotimes (round 2)
           (clrhash counts)
           (verify-mir unit)
           (assert (plusp (hash-table-count counts)))
           (maphash (lambda (function count)
                      (declare (ignore function)) (assert (= count 1))) counts)))
    (setf (symbol-function 'mir-compute-function-identities) original)))
(format t "Verification reuses identities within a check and recomputes on the next check.~%")
