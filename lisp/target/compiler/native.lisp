;;;; Native COMPILE and EVAL normalize compiler modules to independent LIR.
;;;; The backend compiles the program with its image literal bindings,
;;;; including metadata objects appended during normalization.

(in-package #:kiln.compiler)

(defvar *native-compile-count* 0)

(defvar *compiled-function*)

(defvar *available-image-sessions* nil)

(defun call-with-image-session (function)
  "Lease a session exclusively, including across recursive compilation."
  (let ((session (or (pop *available-image-sessions*) (make-session))))
    (unwind-protect
         (progn
           (initialize-session (session-client session) session)
           (funcall function session))
      (clrhash (session-defined-functions session))
      (clrhash (session-source-definitions session))
      (forget-global-descriptions (session-environment session))
      (setf (session-hir-source-files session) (make-hir-buffer))
      (push session *available-image-sessions*))))

(defun native-compile (definition)
  "The function of the lambda expression DEFINITION, compiled into the
running image, in the null lexical environment."
  (let ((pipeline *compiler-pipeline*))
    (call-with-compilation-request
     :native-compile nil
     (lambda (request)
       (call-with-image-session
        (lambda (session)
          (setf (compilation-request-session request) session)
          (native-compile-in-session definition session pipeline))))
     :pipeline :hir)))

(defun native-compile-in-session (definition session &optional (pipeline :hir))
  (let* ((*eval-definition* (and kiln.kernel::*compile-name*
                                (cons kiln.kernel::*compile-name* t)))
         (name (kiln.kir::kir-name "compile-" (incf *native-compile-count*))))
    (multiple-value-bind (module literals)
        (handler-bind ((undefined-function-warning
                         (lambda (condition)
                           (kiln.kernel::note-compilation-unit-functions
                            (undefined-function-names condition))
                           (muffle-warning condition))))
          (compile-module (front-end-forms `((setq *compiled-function* (function ,definition)))
                                           session)
                          name :session session :image t :pipeline pipeline))
      (multiple-value-bind (program bindings) (kiln.kir::normalize-lir-module module literals)
        (let ((init (kiln.sys:%primop :compile-program program bindings
                                            kiln.kir::+backend-target-fingerprint+)))
          (unless init
            (error "kiln-cg could not compile ~S." definition))
          (let ((*compiled-function* nil))
            (funcall init)
            *compiled-function*))))))

;;; EVAL, as SBCL's: forms whose evaluation needs no code
;;; are evaluated directly, the subforms of PROGN and EVAL-WHEN in turn
;;; (so that a DEFMACRO takes effect before the next one is compiled),
;;; macro forms after their expansion; any other form is compiled as the
;;; body of a function of no arguments, which is called.
(defun native-eval (form)
  (let ((*source-origin* (source-origin :form (and (consp form) (first form))
                                       (cst-source-range *eval-source-cst*))))
    (call-with-compilation-request
     :eval nil (lambda (request) (declare (ignore request)) (native-eval-request form))
     :dependencies :fresh :calls :inherit :outputs :inherit :fingerprint :inherit :observers :inherit)))

(defun native-eval-request (form)
  (let ((outermost (not *evaluating*)))
    (multiple-value-prog1
        (let ((*evaluating* t)
              (*eval-definition* nil)
              (*eval-form* form))
          (native-eval-1 form))
      ;; The definitions that depend on those FORM changed.
      (when (and outermost *pending-redefinitions*)
        (update-dependents)))))

(defun native-eval-1 (form)
  (let ((*source-origin* (form-source-origin form)))
  (loop
    (case (toplevel-form-kind form)
      (:symbol
       (multiple-value-bind (expansion macrop) (macroexpand-1 form)
         (if macrop (setf form expansion) (return (symbol-value form)))))
      (:literal (return form))
      (:quote (return (second form)))
      (:function
       (return (if (symbolp (second form)) (fdefinition (second form))
                   (native-eval-toplevel form))))
      (:progn (return (native-eval-body (rest form))))
      (:eval-when
       (multiple-value-bind (action body) (toplevel-eval-when form :eval)
         (return (when (eq action :execute) (native-eval-body body)))))
      (otherwise
       (unless (and (symbolp (first form)) (macro-function (first form)))
         (return (native-eval-toplevel form)))
       (multiple-value-bind (name function-p) (definition-name form)
         (when name
           (return
             (let ((*eval-definition* (cons name function-p)))
               (evaluate-definition name form
                                    (let ((form form))
                                      (lambda () (native-eval-1 (macroexpand-1 form)))))))))
       (note-dependency :macro (first form))
       (setf form (macroexpand-1 form)
             *source-origin* (form-source-origin form)))))))

(defvar *eval-values*)

(defun native-eval-toplevel (form)
  "Compiles FORM as a top-level form (so that the function a definition
defines is not inside another, for its name) and runs it;
returns its values."
  (call-with-image-session
   (lambda (session) (native-eval-in-session form session))))

(defun native-eval-in-session (form session)
  (let ((name (kiln.kir::kir-name "eval-" (incf *native-compile-count*))))
    (multiple-value-bind (module literals)
        (handler-bind ((undefined-function-warning
                         (lambda (condition)
                           (kiln.kernel::note-compilation-unit-functions
                            (undefined-function-names condition))
                           (muffle-warning condition))))
          (compile-module (front-end-forms `((setq *eval-values* (multiple-value-list ,form)))
                                           session)
                          name :session session :image t))
      (let ((init (cached-toplevel-init name module literals (compilation-debug-literals module)
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
