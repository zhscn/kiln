;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(defun mir-double-box-count (body)
  (let* ((session (make-session))
         (module (compile-module (front-end-forms (list body) session)
                                 "double-boxes" :session session))
         (count 0))
    (labels ((visit (node)
               (when (consp node)
                 (when (and (eq (first node) :alloc-fixed)
                            (eql (third node) kiln.kir::+packet-class-double+))
                   (incf count))
                 (dolist (part node) (visit part)))))
      (visit (kiln.kir::kmodule-funcs module)))
    count))

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
