;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(dolist (name '(analyze-hir-native infer-hir-types expand-hir-list-bindings
                hir-prepare-stack-conses hir-prepare-stack-closures hir-lower-toplevel))
  (assert (not (fboundp name))))

(progn
         (let ((session (make-session)))
           (call-with-front-end
            session
            (lambda ()
              (let* ((*hir-eval-client* *client*)
                     (*hir-eval-global* (trucler:global-environment *client* *environment*))
                     (forms (front-end-forms
                             '((function
                                (lambda (x &optional (y (+ x 1)) &key (z (+ y 1)))
                                  (list x y z))))))
                     (root (toplevel-form-ast (first forms)))
                     (function (funcall (funcall (hir-eval-function root) #()))))
                (assert (equal '(10 11 12) (funcall function 10)))
                (assert (equal '(10 20 30) (funcall function 10 20 :z 30)))
                (compile-module forms "mir-parameter-independence" :pipeline :mir)))))
         (let ((session (make-session)))
           (compile-module
            (front-end-forms
             '((lambda (x)
                 (declare (optimize (speed 3) (debug 0)) (double-float x))
                 (flet ((box (y) (declare (double-float y)) (+ y 1d0)))
                   (let ((pair (cons x nil)))
                     (declare (dynamic-extent pair))
                     (values (box (car pair)) pair))))
               (lambda (x)
                 (declare (optimize (speed 3) (debug 0)) (double-float x))
                 (/ 1d0 x)))
             session)
            "mir-allocation-independence" :session session :pipeline :mir)))
(format t "MIR lowering and HIR evaluation operate without legacy native analyses or lowering.~%")
