;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(let* ((buffer (make-hir-buffer)) (*hir-buffer-views* (make-hash-table :test 'eq)))
  (hir-push :first buffer)
  (let ((before (hir-buffer-view buffer)))
    (assert (eq before (hir-buffer-view buffer)))
    (hir-push :second buffer)
    (assert (= 1 (length before)))
    (assert (equalp #(:first :second) (hir-buffer-view buffer)))
    (let ((copy (hir-vector buffer)))
      (setf (svref copy 0) :changed)
      (assert (eq :first (svref (hir-buffer-view buffer) 0))))))

(let* ((forms (front-end-forms '((identity 1))))
       (unit (hir-to-mir (toplevel-form-ast (first forms))))
       (function (mir-at (mir-unit-functions unit) 0))
       (buffer (mir-function-instructions function)))
  (flet ((view (function) (declare (ignore function)) (hir-buffer-view buffer)))
    (let ((before (mir-analysis function :view-one #'view)))
      (assert (eq before (mir-analysis function :view-two #'view)))
      (mir-run-pass unit function #'identity :changes '(:instructions))
      (assert (not (eq before (mir-analysis function :view-three #'view)))))))

;; Independent verification must see raw same-length edits, even if a read
;; scope and optimization caches already contain snapshots of the old body.
(let* ((forms (front-end-forms '((identity 1))))
       (unit (hir-to-mir (toplevel-form-ast (first forms))))
       (function (mir-at (mir-unit-functions unit) 0))
       (buffer (mir-function-instructions function))
       (*hir-buffer-views* (make-hash-table :test 'eq))
       (before (hir-buffer-view buffer))
       (old (svref before 0)) (invalid (copy-mir-instruction old)))
  (setf (mir-instruction-effects invalid) -1
        (svref (hir-buffer-data buffer) 0) invalid)
  (assert (handler-case (progn (verify-mir unit) nil) (mir-error () t)))
  (setf (svref (hir-buffer-data buffer) 0) old)
  (verify-mir unit))
(format t "Read views share within a revision, refresh after append, and remain separate from verification.~%")
