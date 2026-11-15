;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)
(let ((session (make-session)) (allowed nil) (calls 0) (nested nil)
      (infer (symbol-function 'infer-hir-types))
      (saved (mapcar (lambda (name) (cons name (symbol-function name)))
                     '(resolve-hir-function-aliases propagate-hir-function-identities
                       hir-inline-call hir-inline-candidate-p expand-hir-list-bindings))))
  (unwind-protect
       (progn
         (dolist (entry saved)
           (let ((name (car entry)) (function (cdr entry)))
             (setf (symbol-function name)
                   (lambda (&rest args)
                     (unless allowed (error "Legacy optimization ~S reached semantic/MIR preparation" name))
                     (incf calls) (apply function args)))))
         (call-with-front-end
          session
          (lambda ()
            (let* ((*hir-eval-client* *client*)
                   (*hir-eval-global* (trucler:global-environment *client* *environment*))
                   (*source-file* "hir-native-preparation") (*toplevel-source* nil)
                   (forms (front-end-forms
                           '((function
                              (lambda (x)
                                (let ((n x))
                                  (flet ((step () (incf n)))
                                    (let ((alias #'step) (pair (list 1 2)))
                                      (lambda () (+ (funcall alias) (car pair)))))))))))
                   (root (toplevel-form-ast (first forms)))
                   (maker (funcall (funcall (hir-eval-function root) #())))
                   (counter (funcall maker 10)))
              (assert (= 12 (funcall counter)))
              (assert (not (logtest 32 (hir-fun-flags root))))
              (compile-module forms "mir-before-legacy" :pipeline :mir)
              (assert (zerop calls))
              (setf allowed t
                    (symbol-function 'infer-hir-types)
                    (lambda (&rest args)
                      (unless allowed (error "HIR inference reached a MIR compilation"))
                      (unless nested
                        (setf nested t)
                        (let ((previous allowed))
                          (unwind-protect
                               (progn
                                 (setf allowed nil)
                                 (compile-module
                                  (front-end-forms
                                   '((lambda (y)
                                       (flet ((keep (z) (list z)))
                                         (keep y) (keep y)))))
                                  "mir-during-legacy" :pipeline :mir))
                            (setf allowed previous))))
                      (apply infer args)))
              (compile-module forms "legacy-lazy" :pipeline :hir)
              (assert nested)
              (assert (plusp calls))
              (assert (logtest 32 (hir-fun-flags root)))
              (assert (= 13 (funcall counter)))
              (setf allowed nil)
              (compile-module forms "mir-after-legacy" :pipeline :mir)
              (assert (= 14 (funcall counter)))))))
    (setf (symbol-function 'infer-hir-types) infer)
    (dolist (entry saved) (setf (symbol-function (car entry)) (cdr entry)))))
(format t "Legacy HIR optimizations are lazy and preserve existing evaluator closures.~%")
