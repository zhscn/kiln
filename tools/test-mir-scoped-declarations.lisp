;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(defun mir-scoped-check-types (form)
  (let* ((forms (front-end-forms (list form)))
         (unit (hir-to-mir (toplevel-form-ast (first forms))))
         (types nil))
    (loop for function across (hir-vector (mir-unit-functions unit))
          do (loop for instruction across (hir-vector (mir-function-instructions function))
                   when (= 11 (mir-instruction-kind instruction))
                     do (push (hir-declaration-expanded (mir-instruction-data instruction)) types)))
    types))

(let ((types (mir-scoped-check-types
              '(lambda (value)
                 (declare (integer value))
                 (locally (declare (type (unsigned-byte 8) value)) value)))))
  (assert (some (lambda (type)
                  (and (consp type) (eq (car type) 'and)
                       (member 'integer (cdr type))
                       (member '(unsigned-byte 8) (cdr type) :test #'equal)))
                types)))
(assert (member nil (mir-scoped-check-types
                     '(lambda (value) (locally (declare (type nil value)) value)))))
(assert (null (mir-scoped-check-types
               '(lambda (value) (locally (declare (fixnum value)) nil) value))))
(format t "MIR reconstructs scoped and empty declaration checks from lexical declarations.~%")
