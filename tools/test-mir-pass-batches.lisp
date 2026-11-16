;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(let* ((forms (front-end-forms '((flet ((f (x) x) (g (y) y)) (list #'f #'g)))))
       (unit (hir-to-mir (toplevel-form-ast (first forms))))
       (functions (hir-vector (mir-unit-functions unit)))
       (original (symbol-function 'mir-verify-private-entries))
       (checks 0) (computations 0))
  (flet ((compute (unit) (declare (ignore unit)) (incf computations)))
    (mir-unit-analysis unit :batch-test #'compute)
    (unwind-protect
         (progn
           (setf (symbol-function 'mir-verify-private-entries)
                 (lambda (unit) (incf checks) (funcall original unit)))
           (mir-run-passes unit
             (loop for function across functions
                   collect (cons function
                                 (lambda (function)
                                   (declare (ignore function))
                                   (mir-unit-analysis unit :batch-test #'compute)))))
           (assert (= checks 1))
           ;; A query in one callback must not survive the next callback's edit.
           (assert (= computations (1+ (length functions)))))
      (setf (symbol-function 'mir-verify-private-entries) original)))
  (assert
    (handler-case
        (progn
          (mir-run-passes unit
            (list (cons (svref functions 1)
                        (lambda (function) (incf (mir-function-required function))))))
          nil)
      (mir-error () t))))
(format t "Body batches retain layout checks and invalidate analyses before each rewrite.~%")
