;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(defun mir-fast-double-box-count (module)
  (let ((slow-callee
          (list :object-address
                (kiln.kir::kir-name "kiln_sym_" (symbol-label 'kiln.kernel::controlled-real-arithmetic))
                :general)))
    (labels ((slow-block-p (tree)
               (or (equal tree slow-callee)
                   (and (consp tree)
                        (or (slow-block-p (car tree)) (slow-block-p (cdr tree))))))
             (boxes (tree)
               (cond ((atom tree) 0)
                     ;; This block handles exceptional operands or rounding modes
                     ;; through the boxed arithmetic ABI.
                     ((and (eq (car tree) :block) (slow-block-p tree)) 0)
                     ((and (eq (car tree) :alloc-fixed)
                           (eql (third tree) kiln.kir::+packet-class-double+)) 1)
                     (t (+ (boxes (car tree)) (boxes (cdr tree)))))))
      (boxes (kiln.kir::kmodule-funcs module)))))

(defun mir-double-box-count (body)
  (let ((session (make-session)))
    (mir-fast-double-box-count
     (compile-module (front-end-forms (list body) session)
                     "double-boxes" :session session))))

;; Only the result crossing the object ABI needs a box. Source-visible
;; bindings remain object uses at high debug, so their observations survive.
(assert (= 1 (mir-double-box-count
               '(defun high-debug-double-chain (x y)
                  (declare (double-float x y) (optimize (speed 3) (debug 3)))
                  (+ (* x y) y)))))
(assert (= 2 (mir-double-box-count
               '(defun observed-double-chain (x y)
                  (declare (double-float x y) (optimize (speed 3) (debug 3)))
                  (let ((product (* x y)))
                    (+ product y))))))
(format t "MIR boxes high-debug doubles at object and observation boundaries.~%")
