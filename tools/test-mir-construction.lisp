;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(dolist (size '(1 16 128))
  (let* ((bindings (loop repeat size collect (list (gensym "UNUSED") 0)))
         (forms (front-end-forms `((let ,bindings (if (identity t) 1 2)))))
         (unit (hir-to-mir (toplevel-form-ast (first forms))))
         (function (mir-at (mir-unit-functions unit) 0)))
    (assert (<= (loop for block across (hir-vector (mir-function-blocks function))
                      sum (length (mir-block-parameters block))) 1))
    (loop for instruction across (hir-vector (mir-function-instructions function))
          do (assert (every (lambda (id) (not (minusp id))) (mir-instruction-operands instruction))))))
(format t "Undemanded lexical bindings do not become SSA block parameters.~%")
