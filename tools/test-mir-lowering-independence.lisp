;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

;; Remove legacy native analyses and lowering while exercising the MIR
;; consumer and HIR evaluator. Restore the functions for other suites.
(let ((saved nil))
  (dolist (file '("lisp/hir/types.lisp" "lisp/hir/escape.lisp" "lisp/hir/lower.lisp"))
    (with-open-file (input (asdf:system-relative-pathname "kiln" file))
      (loop for form = (read input nil :eof) until (eq form :eof)
            when (and (consp form) (eq (car form) 'defun))
              do (push (cons (second form) (symbol-function (second form))) saved))))
  (unwind-protect
       (progn
         (dolist (entry saved) (fmakunbound (car entry)))
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
    (dolist (entry saved) (setf (symbol-function (car entry)) (cdr entry)))))
(format t "MIR lowering and HIR evaluation operate without legacy native analyses or lowering.~%")
