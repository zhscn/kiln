;;;; Run after tools/env.lisp and (ql:quickload "kiln"). Requires kiln-cg.
;;;; Compiles the kernel itself through MIR before running a dependent module.
(in-package #:kiln.compiler)

(let* ((root (asdf:system-source-directory "kiln"))
       (kernel (merge-pathnames "build/mir-kernel/kernel.lir" root))
       (probe (merge-pathnames "build/mir-kernel/probe.lir" root))
       (session (make-session)))
  (ensure-directories-exist kernel)
  (multiple-value-bind (asts packages) (front-end kiln::*kernel-files* session)
    (kiln::write-module
     (compile-module asts "kernel" :session session :defined-packages packages :pipeline :mir
                     :extra-symbols (let ((symbols nil))
                                      (do-external-symbols (symbol :common-lisp symbols)
                                        (push symbol symbols))))
     kernel))
  (kiln::write-module
   (compile-module
    (front-end-forms
     '((defun mir-kernel-probe (x) (symbolp x))
       (defun (setf mir-kernel-probe) (value object) (cons value object))
       (print (list (mir-kernel-probe :symbol) (mir-kernel-probe 42)
                    (funcall #'(setf mir-kernel-probe) :value :object)))
       (print (= 1 (length (multiple-value-list
                           (setf (fdefinition 'mir-kernel-probe) (lambda (x) (integerp x)))))))
       (print (list (mir-kernel-probe :symbol) (mir-kernel-probe 42)))
       (flet ((sum (a b) (+ a b)))
         (declare (notinline sum))
         (print (list (= (sum 9223372036854775808 2) 9223372036854775810)
                      (= (sum 1/3 1/6) 1/2)
                      (= (sum 1d0 2) 3d0)))))
     session)
    "mir-kernel-probe" :session session :pipeline :mir)
   probe)
  (let ((text (uiop:run-program
               (list (namestring (merge-pathnames "target/debug/kiln-cg" root))
                     "jit" (namestring kernel) (namestring probe))
               :output :string :error-output :string)))
    (assert (equal text (format nil "(T NIL (:VALUE . :OBJECT))~%T~%(NIL T)~%(T T T)~%"))
            () "Unexpected kernel probe output: ~S" text)))
(format t "MIR kernel initialization and function definition execution passed.~%")
