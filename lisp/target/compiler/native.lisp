;;;; COMPILE to native code (M5.5, docs/11 §11): the lambda expression is
;;;; compiled by the image's front end and lower.lisp into a KIR module
;;;; whose literals are the image's objects, which kiln-cg, linked into the
;;;; runtime, compiles into memory (kiln_rt_jit). The compiler module's
;;;; last file: from here on the kernel's COMPILE and EVAL (so LOAD) use
;;;; it, not Maclina.

(in-package #:kiln.compiler)

(defvar *native-compile-count* 0)

(defvar *compiled-function*)

(defun native-compile (definition)
  "The function of the lambda expression DEFINITION, compiled into the
running image, in the null lexical environment."
  (let* ((session (make-session))
         (name (kiln.kir::kir-name "compile-" (incf *native-compile-count*))))
    (multiple-value-bind (module literals)
        (handler-bind ((undefined-function-warning #'muffle-warning))
          (compile-module (front-end-forms `((setq *compiled-function* (function ,definition)))
                                           session)
                          name :session session :image t))
      (let ((init (kiln.sys:%primop :jit (kiln.kir::module-string module) literals)))
        (unless init
          (error "kiln-cg could not compile ~S." definition))
        (let ((*compiled-function* nil))
          (funcall init)
          *compiled-function*)))))

;;; EVAL (docs/11 §12), as SBCL's: forms whose evaluation needs no code
;;; are evaluated directly, the subforms of PROGN and EVAL-WHEN in turn
;;; (so that a DEFMACRO takes effect before the next one is compiled),
;;; macro forms after their expansion; any other form is compiled as the
;;; body of a function of no arguments, which is called.
(defun native-eval (form)
  (loop
    (cond ((symbolp form)
           (return (kiln.kernel::maclina-eval form)))
          ((atom form)
           (return form))
          ((eq (first form) 'quote)
           (return (second form)))
          ((and (eq (first form) 'function) (symbolp (second form)))
           (return (fdefinition (second form))))
          ((eq (first form) 'progn)
           (return (native-eval-body (rest form))))
          ((eq (first form) 'eval-when)
           (return (when (or (member :execute (second form))
                             (member 'eval (second form)))
                     (native-eval-body (cddr form)))))
          ((and (symbolp (first form)) (macro-function (first form)))
           (setf form (macroexpand-1 form)))
          (t
           (return (funcall (native-compile `(lambda () ,form))))))))

(defun native-eval-body (forms)
  (if (null forms)
      nil
      (loop for (form . more) on forms
            if more do (native-eval form)
            else return (native-eval form))))

(setf kiln.kernel::*compile-function* 'native-compile)
(setf kiln.kernel::*eval-function* 'native-eval)
