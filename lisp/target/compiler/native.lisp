;;;; COMPILE to native code (M5.5): the lambda expression is
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

;;; EVAL, as SBCL's: forms whose evaluation needs no code
;;; are evaluated directly, the subforms of PROGN and EVAL-WHEN in turn
;;; (so that a DEFMACRO takes effect before the next one is compiled),
;;; macro forms after their expansion; any other form is compiled as the
;;; body of a function of no arguments, which is called.
(defun native-eval (form)
  (let ((outermost (not *evaluating*)))
    (multiple-value-prog1
        (let ((*evaluating* t)
              (*dependencies* (list :dependencies))
              (*eval-definition* nil)
              (*eval-form* form))
          (native-eval-1 form))
      ;; The definitions that depend on those FORM changed.
      (when (and outermost *pending-redefinitions*)
        (update-dependents)))))

(defun native-eval-1 (form)
  (loop
    (cond ((symbolp form)
           (multiple-value-bind (expansion macrop) (macroexpand-1 form)
             (if macrop
                 (setf form expansion)
                 (return (kiln.kernel::maclina-eval form)))))
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
           ;; The functions a definition defines are named after it
           ;;, although its expansion is compiled; its
           ;; dependencies are recorded.
           (multiple-value-bind (name function-p) (definition-name form)
             (when name
               (return
                 (let ((*eval-definition* (cons name function-p)))
                   (evaluate-definition name form
                                        (let ((form form))
                                          (lambda () (native-eval-1 (macroexpand-1 form)))))))))
           (note-dependency :macro (first form))
           (setf form (macroexpand-1 form)))
          (t
           (return (native-eval-toplevel form))))))

(defvar *eval-values*)

(defun native-eval-toplevel (form)
  "Compiles FORM as a top-level form (so that the function a definition
defines is not inside another, for its name) and runs it;
returns its values."
  (let* ((session (make-session))
         (name (kiln.kir::kir-name "eval-" (incf *native-compile-count*))))
    (multiple-value-bind (module literals)
        (handler-bind ((undefined-function-warning #'muffle-warning))
          (compile-module (front-end-forms `((setq *eval-values* (multiple-value-list ,form)))
                                           session)
                          name :session session :image t))
      (let* ((kir (kiln.kir::module-string module))
             (init (cached-toplevel-init name kir literals (compilation-debug-literals module)
                                        (kiln.kir::kmodule-replayable-p module))))
        (unless init
          (error "kiln-cg could not compile ~S." form))
        (let ((*eval-values* nil))
          (funcall init)
          (values-list *eval-values*))))))

(defun native-eval-body (forms)
  (if (null forms)
      nil
      (loop for (form . more) on forms
            ;; Within a definition (the PROGN of a DEFUN's expansion),
            ;; its name stays.
            if more do (let ((*eval-definition* *eval-definition*)) (native-eval-1 form))
            else return (let ((*eval-definition* *eval-definition*)) (native-eval-1 form)))))

(setf kiln.kernel::*compile-function* 'native-compile)
(setf kiln.kernel::*eval-function* 'native-eval)

(setf clostrophilia::*specialization-compiler* 'native-compile)
