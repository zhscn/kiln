;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(let ((session (make-session)))
  (call-with-front-end
   session
   (lambda ()
     (let* ((*hir-eval-client* *client*)
            (*hir-eval-global* (trucler:global-environment *client* *environment*))
            (forms (front-end-forms
                    '((function
                       (lambda (x)
                         (let ((n x))
                           (flet ((step () (incf n)))
                             (let ((alias #'step) (pair (list 1 2)))
                               (lambda () (+ (funcall alias) (car pair)))))))))))
            (root (toplevel-form-ast (first forms)))
            (maker (funcall (funcall (hir-eval-function root) #())))
            (counter (funcall maker 10))
            (body (hir-fun-body root)))
       (assert (= 12 (funcall counter)))
       (dotimes (index 3)
         (compile-module forms "mir-shared-preparation" :pipeline :mir)
         (assert (eq body (hir-fun-body root)))
         (assert (= (+ 13 index) (funcall counter))))))))
(format t "MIR compilation preserves the HIR tree and existing evaluator closures.~%")
