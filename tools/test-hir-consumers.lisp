;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(let ((session (make-session)))
  (call-with-front-end
   session
   (lambda ()
     (let ((*hir-eval-client* *client*)
           (*hir-eval-global* (trucler:global-environment *client* *environment*)))

(let ((infer (symbol-function 'infer-hir-types)))
  (unwind-protect
       (progn
         (setf (symbol-function 'infer-hir-types)
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (error "HIR-native inference reached the semantic or MIR path")))
         (assert (= 3 (hir-eval '(+ 1 2) *environment*)))
         (let* ((forms (front-end-forms '((+ 1 2))))
                (root (toplevel-form-ast (first forms))))
           (assert (= 3 (funcall (funcall (hir-eval-function root) #()))))
           (compile-module forms "consumer-without-hir-inference" :pipeline :mir)))
    (setf (symbol-function 'infer-hir-types) infer)))

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
  (assert (not (logtest 512 (hir-fun-flags root))))
  (compile-module forms "consumer-mir" :pipeline :mir)
  (assert (not (logtest 512 (hir-fun-flags root))))
  (compile-module forms "consumer-one")
  (assert (logtest 512 (hir-fun-flags root)))
  (assert (= 12 (funcall counter)))
  (analyze-hir root nil)
  (assert (not (logtest 512 (hir-fun-flags root))))
  (compile-module forms "consumer-two")
  (assert (logtest 512 (hir-fun-flags root)))
  (assert (= 13 (funcall counter)))
  (let ((other (funcall (funcall (funcall (hir-eval-function root) #())) 20)))
    (assert (= 21 (funcall other))))
  (assert (= 14 (funcall counter))))

(let* ((*source-file* "consumer-specialization") (*toplevel-source* nil)
       (forms (front-end-forms
               '((function (lambda (x)
                             (declare (optimize (speed 3) (debug 0)))
                             (flet ((add (a) (+ a 1)))
                               (let ((pair (cons (add x) (add 2))))
                                 (+ (car pair) (cdr pair)))))))))
       (root (toplevel-form-ast (first forms)))
       (function (funcall (funcall (hir-eval-function root) #()))))
  (assert (= 14 (funcall function 10)))
  (compile-module forms "consumer-specialization")
  (assert (= 24 (funcall function 20)))
  (assert (= 34 (funcall (funcall (funcall (hir-eval-function root) #())) 30)))
  (compile-module forms "consumer-specialization-mir" :pipeline :mir))

(let* ((*source-file* "consumer-load-time") (*toplevel-source* nil)
       (forms (front-end-forms '((load-time-value (list 1 2)))))
       (root (toplevel-form-ast (first forms))))
  (assert (equal '(1 2) (funcall (funcall (hir-eval-function root) #()))))
  (compile-module forms "consumer-load-time")
  (assert (equal '(1 2) (funcall (funcall (hir-eval-function root) #())))))

))))

(format t "HIR interpreter and native emission state are independent.~%")
