;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(let ((session (make-session)))
  (call-with-front-end
   session
   (lambda ()
     (let ((*hir-eval-client* *client*)
           (*hir-eval-global* (trucler:global-environment *client* *environment*)))

(let* ((*source-file* "consumer-isolation") (*toplevel-source* nil)
       (forms (front-end-forms
               '((function (lambda (x)
                             (let ((n x))
                               (lambda () (incf n))))))))
       (root (toplevel-form-ast (first forms)))
       (maker (hir-eval-function root))
       (function (funcall (funcall maker #())))
       (counter (funcall function 10)))
  (assert (= 11 (funcall counter)))
  (compile-module forms "consumer-one")
  (assert (= 12 (funcall counter)))
  (compile-module forms "consumer-two")
  (assert (= 13 (funcall counter)))
  (let ((other (funcall (funcall (funcall (hir-eval-function root) #())) 20)))
    (assert (= 21 (funcall other))))
  (assert (= 14 (funcall counter))))

(let* ((*source-file* "consumer-load-time") (*toplevel-source* nil)
       (forms (front-end-forms '((load-time-value (list 1 2)))))
       (root (toplevel-form-ast (first forms))))
  (assert (equal '(1 2) (funcall (funcall (hir-eval-function root) #()))))
  (compile-module forms "consumer-load-time")
  (assert (equal '(1 2) (funcall (funcall (hir-eval-function root) #())))))

))))

(format t "HIR interpreter and native emission state are independent.~%")
