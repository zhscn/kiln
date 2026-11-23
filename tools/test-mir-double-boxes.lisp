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
                           (eql (third tree) kiln.kir::+packet-class-double+))
                      (let ((payload (first (fourth tree))))
                        (assert (eq (svref payload 2) :f64)))
                      1)
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
(assert (= 1 (mir-double-box-count
               '(defun double-fold (a b c d)
                  (declare (double-float a b c d) (optimize (speed 3) (debug 0)))
                  (+ (* a b c) (- d c b) (/ a c d))))))

(let* ((session (make-session))
       (form '(defun checked-reciprocal (x)
                (declare (double-float x) (optimize (speed 3) (safety 3)))
                (/ x)))
       (module (compile-module (front-end-forms (list form) session)
                               "checked-reciprocal" :session session)))
  (labels ((nonfinite-branch-p (tree)
             (and (consp tree)
                  (or (and (eq (first tree) :br)
                           (consp (second tree))
                           (eq (caadr tree) :f64-nonfinite))
                      (nonfinite-branch-p (car tree))
                      (nonfinite-branch-p (cdr tree))))))
    (assert (nonfinite-branch-p (kiln.kir::kmodule-funcs module)))))
(format t "MIR boxes high-debug doubles at object and observation boundaries.~%")
