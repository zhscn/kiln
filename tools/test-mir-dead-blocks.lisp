;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(defun mir-dead-block-unit (body)
  (let* ((*source-file* "mir-dead-block-model") (*toplevel-source* nil)
         (forms (front-end-forms (list `(lambda (x) (declare (optimize (speed 3) (debug 1))) ,body))))
         (*toplevel* (first forms)))
    (hir-to-mir (toplevel-form-ast *toplevel*))))

(dolist (body
         '((block out
             (flet ((f (a &optional (b x) (c x)) (return-from out -7)))
               (f 1 2 3) (multiple-value-call #'f (values 1 2))))
           (flet ((target (a) (+ x a)))
             (if t (target 1) (flet ((consumer () (target 2))) (consumer))))
           (if nil
               (flet ((target (a) (+ x a)))
                 (flet ((consumer () (multiple-value-call #'target (values 1)))) (consumer)))
               0)
           (progn
             (if nil (let ((*dead-block-special* 1)) (declare (special *dead-block-special*)) *dead-block-special*) 0)
             (let ((*dead-block-special* (list x)))
               (declare (special *dead-block-special*))
               (catch 'done (unwind-protect (throw 'done *dead-block-special*) (identity x)))))))
  (let* ((unit (mir-dead-block-unit body)) (caller (mir-at (mir-unit-functions unit) 1)))
    (mir-optimize-unit unit)
    (verify-mir unit)
    (assert (= (logcount (mir-reachable-blocks caller)) (hir-buffer-count (mir-function-blocks caller))))
    (let ((revision (mir-function-revision caller)))
      (assert (not (mir-prune-unreachable-blocks unit caller)))
      (assert (= revision (mir-function-revision caller))))))
(format t "Dead CFG removal preserves private calls, capture boundaries and dense region/SSA IDs.~%")
