;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(defun mir-contract-test-unit ()
  (let ((forms (front-end-forms '((list (lambda () 1) (lambda () 2))))))
    (hir-to-mir (toplevel-form-ast (first forms)))))

(let* ((*mir-check-pass-contracts* t) (unit (mir-contract-test-unit))
       (function (mir-at (mir-unit-functions unit) 0)))
  (mir-run-pass unit function #'identity :changes '(:instructions))
  (mir-run-passes unit (loop for entry across (hir-vector (mir-unit-functions unit))
                             collect (cons entry #'identity))))

;; Mutating a different body cannot silently leave its cache revision intact.
(let* ((*mir-check-pass-contracts* t) (unit (mir-contract-test-unit))
       (function (mir-at (mir-unit-functions unit) 0))
       (other (mir-at (mir-unit-functions unit) 1)))
  (assert
    (handler-case
        (progn
          (mir-run-pass unit function
            (lambda (function)
              (declare (ignore function))
              (let ((constant (find 0 (hir-vector (mir-function-instructions other))
                                    :key #'mir-instruction-kind)))
                (setf (mir-instruction-data constant) 'changed))))
          nil)
      (mir-error () t))))

(let* ((*mir-check-pass-contracts* t) (unit (mir-contract-test-unit))
       (function (mir-at (mir-unit-functions unit) 1)))
  (assert
    (handler-case
        (progn
          (mir-run-pass unit function
            (lambda (function)
              (let ((term (mir-block-terminator (mir-at (mir-function-blocks function) 0))))
                (setf (mir-terminator-kind term) 3)))
            :changes '(:instructions))
          nil)
      (mir-error () t))))

(let* ((unit (mir-contract-test-unit)) (function (mir-at (mir-unit-functions unit) 0)))
  (dolist (changes '(nil (:typo) :instructions))
    (assert (handler-case (progn (mir-run-pass unit function #'identity :changes changes) nil)
              (mir-error () t))))
  (assert (handler-case
              (progn (mir-run-pass unit function
                       (lambda (function) (mir-run-pass unit function #'identity))) nil)
            (mir-error () t))))

;; Shared literal graphs can contain cycles and are not owned MIR nodes.
(let* ((*mir-check-pass-contracts* t)
       (literal (list :cycle))
       (forms (progn (setf (cdr literal) literal) (front-end-forms (list (list 'quote literal)))))
       (unit (hir-to-mir (toplevel-form-ast (first forms)))))
  (mir-run-pass unit (mir-at (mir-unit-functions unit) 0) #'identity))
(format t "MIR edit contracts enforce scope and declared changes, including cyclic literal inputs.~%")

(dolist (unit-pass '(nil t))
  (let* ((forms (front-end-forms '((flet ((f () 1)) (declare (notinline f)) (f)))))
         (unit (hir-to-mir (toplevel-form-ast (first forms))))
         (function (mir-at (mir-unit-functions unit) 1))
         (constant (find-if (lambda (instruction)
                              (and (= 0 (mir-instruction-kind instruction))
                                   (eql 1 (mir-instruction-data instruction))))
                            (hir-vector (mir-function-instructions function))))
         (result (mir-instruction-result constant)))
    (mir-infer-types function)
    (mir-infer-calls unit)
    (flet ((edit ()
             (assert (equal '(integer 1 1) (svref (mir-infer-types function) result)))
             (mir-infer-calls unit)
             (setf (mir-instruction-data constant) 'changed)
             (assert (eq 'symbol (svref (mir-infer-types function) result)))
             (assert (eq 'symbol (svref (svref (mir-call-analysis-types (mir-infer-calls unit)) 1) result)))))
      (if unit-pass
          (mir-run-unit-pass unit (lambda (unit) (declare (ignore unit)) (edit)))
          (mir-run-pass unit function (lambda (function) (declare (ignore function)) (edit)))))
    (assert (eq 'symbol (svref (mir-infer-types function) result)))
    (assert (eq 'symbol (svref (svref (mir-call-analysis-types (mir-infer-calls unit)) 1) result)))))

(let* ((unit (mir-contract-test-unit)) (function (mir-at (mir-unit-functions unit) 0)))
  (assert (handler-case
              (progn (mir-run-pass unit function (lambda (function) (incf (mir-function-id function)))) nil)
            (mir-error () t))))
(format t "Analysis queries during edits are fresh and cannot publish intermediate cache entries.~%")
