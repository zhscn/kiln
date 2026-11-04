(in-package #:kiln.compiler)

;;;; Front end (M2): Eclector reads CSTs; top-level forms are processed
;;;; here as in COMPILE-FILE (CLHS 3.2.3.1); Common-boot turns each form to
;;;; be compiled into an Iconoclast AST, which SIMPLIFY-AST reduces to the
;;;; subset that lower.lisp translates to KIR. See docs/08-m2-front-end.md.
;;;;
;;;; Compile-time evaluation (EVAL-WHEN :COMPILE-TOPLEVEL, macro
;;;; definitions, DEFVAR proclamations) runs in the host through
;;;; Common-boot's HIR evaluator, in a Clostrum environment that holds the
;;;; compile-time definitions. Host CL functions are imported into it, so
;;;; macro expanders can call them.

(defclass client (trucler-reference:client cbe:client)
  ())

(defmethod cb:convert-with-parser-p ((client client) operator)
  (special-operator-p operator))

(defmethod cb:convert-with-ordinary-macro-p ((client client) operator)
  (cmd:macro-function-exists-p operator))

(defvar *client*)
(defvar *defined-functions*)            ; names defined by DEFUN in this file
(defvar *referenced-functions*)         ; undefined names seen by Common-boot

(defmethod cmd:defun-compile-time-action ((client client) name lambda-list environment)
  (declare (ignore lambda-list environment))
  (setf (gethash name *defined-functions*) t)
  nil)

(define-condition undefined-function-warning (style-warning)
  ((names :initarg :names :reader undefined-function-names))
  (:report (lambda (c s)
             (format s "undefined function~P: ~{~S~^, ~}"
                     (length (undefined-function-names c))
                     (undefined-function-names c)))))
(defvar *environment*)                  ; Trucler environment

(defun global-environment ()
  (trucler:global-environment *client* *environment*))

(defun proclaim-in (client genv declaration)
  (when (and (consp declaration) (eq (first declaration) 'special))
    (dolist (name (rest declaration))
      (clo:make-variable client genv name)))
  nil)

(defun import-host-functions (client genv)
  (do-external-symbols (s '#:common-lisp)
    (when (and (fboundp s) (not (macro-function s)) (not (special-operator-p s)))
      (setf (clo:fdefinition client genv s) (fdefinition s)))
    (let ((setf-name `(setf ,s)))
      (when (fboundp setf-name)
        (setf (clo:fdefinition client genv setf-name) (fdefinition setf-name)))))
  ;; Functions that consult the global environment must use the
  ;; compile-time environment, not the host's.
  (flet ((def (name function)
           (setf (clo:fdefinition client genv name) function))
         (resolve (f)
           (if (functionp f) f (clo:fdefinition client genv f))))
    (def 'macro-function
      (lambda (name &optional env)
        (declare (ignore env))
        (clo:macro-function client genv name)))
    (def '(setf macro-function)
      (lambda (function name &optional env)
        (declare (ignore env))
        (setf (clo:macro-function client genv name) function)))
    (def 'fdefinition (lambda (name) (clo:fdefinition client genv name)))
    (def 'symbol-function (lambda (name) (clo:fdefinition client genv name)))
    (def '(setf fdefinition)
      (lambda (function name) (setf (clo:fdefinition client genv name) function)))
    (def 'fboundp (lambda (name) (clo:fboundp client genv name)))
    (def 'symbol-value (lambda (name) (clo:symbol-value client genv name)))
    (def '(setf symbol-value)
      (lambda (value name) (setf (clo:symbol-value client genv name) value)))
    (def 'boundp (lambda (name) (clo:boundp client genv name)))
    (def 'proclaim (lambda (declaration) (proclaim-in client genv declaration)))
    (def 'funcall (lambda (f &rest args) (apply (resolve f) args)))
    (def 'apply (lambda (f &rest args) (apply #'apply (resolve f) args)))))

(defun make-compile-environment (client)
  (let* ((env (cb:create-environment))
         (genv (trucler:global-environment client env)))
    (import-host-functions client genv)
    ;; Eclector reads `X as (ECLECTOR.READER:QUASIQUOTE X); its expansion
    ;; uses only APPEND, LIST and QUOTE. SICL does the same
    ;; (New-boot/Shared/define-backquote-macros.lisp).
    (setf (clo:macro-function client genv 'eclector.reader:quasiquote)
          (macro-function 'eclector.reader:quasiquote))
    (setf (clo:fdefinition client genv 'eclector.reader::expand)
          (fdefinition 'eclector.reader::expand))
    ;; LOOP is Khazern's, expanded in the host; its expansions use only
    ;; standard operators.
    (setf (clo:macro-function client genv 'loop)
          (macro-function 'khazern-extrinsic:loop))
    (when (macro-function 'khazern-extrinsic:loop-finish)
      (setf (clo:macro-function client genv 'loop-finish)
            (macro-function 'khazern-extrinsic:loop-finish)))
    env))

;;; SETQ of a symbol macro is SETF of its expansion (CLHS 3.1.2.1.1);
;;; Common-boot has no method for it, so the form is rewritten before
;;; conversion. WITH-SLOTS and WITH-ACCESSORS rely on this.

(defun symbol-macro-expansion (client environment name)
  "The expansion of NAME if it names a symbol macro in ENVIRONMENT, and
true; else NIL and NIL."
  (if (symbolp name)
      (let ((d (trucler:describe-variable client environment name)))
        (if (typep d 'trucler:symbol-macro-description)
            (values (trucler:expansion d) t)
            (values nil nil)))
      (values nil nil)))

(defmethod cb::convert :around ((client client) cst environment)
  (let ((form (cst:raw cst)))
    (if (and (consp form)
             (eq (first form) 'setq)
             (loop for (var) on (rest form) by #'cddr
                   thereis (nth-value 1 (symbol-macro-expansion client environment var))))
        (let ((rewritten
                `(progn
                   ,@(loop for (var value) on (rest form) by #'cddr
                           collect (multiple-value-bind (expansion macrop)
                                       (symbol-macro-expansion client environment var)
                                     (if macrop
                                         `(setf ,expansion ,value)
                                         `(setq ,var ,value)))))))
          (call-next-method client (cst:reconstruct client rewritten cst) environment))
        (call-next-method))))

;;; Reading

(defun map-file-csts (function path)
  "Reads the forms of PATH one at a time and calls FUNCTION on each CST
before reading the next, so that IN-PACKAGE takes effect for the rest of
the file. Reading starts in KILN-USER."
  (with-open-file (in path)
    (let ((*package* (find-package '#:kiln-user))
          (*read-eval* nil))
      (loop with eof = (list nil)
            for cst = (eclector.concrete-syntax-tree:read in nil eof)
            until (eq cst eof)
            do (funcall function cst)))))

;;; Top-level form processing (CLHS 3.2.3.1)

(defvar *toplevel-asts*)                ; simplified ASTs, most recent first

(defun cst-list (cst)
  "The elements of the proper-list CST."
  (loop for c = cst then (cst:rest c)
        while (cst:consp c)
        collect (cst:first c)))

(defun compile-time-eval (cst)
  (cb:eval-cst *client* cst *environment*))

(defun simplify (ast)
  (cbah::simplify-ast ast))

(defun compile-toplevel-form (cst compile-time-too)
  (when compile-time-too
    (compile-time-eval cst))
  (push (simplify (cb:cst-to-ast *client* cst *environment*)) *toplevel-asts*))

(defun macroexpand-toplevel (form)
  "Returns the expansion of FORM and true if FORM is a macro form."
  (let ((op (first form)))
    (cond ((special-operator-p op) (values nil nil))
          (t
           (let ((description (trucler:describe-function *client* *environment* op)))
             (cond ((and (typep description 'trucler:macro-description)
                         (not (eq op 'defmacro)))
                    (values (funcall (trucler:expander description) form *environment*) t))
                   ((cmd:macro-function-exists-p op)
                    (values (cmd:macroexpand-1 form *environment*) t))
                   (t (values nil nil))))))))

(defun process-eval-when (cst compile-time-too)
  (let* ((parts (cst-list (cst:rest cst)))
         (situations (cst:raw (first parts)))
         (body (rest parts))
         (ct (intersection situations '(:compile-toplevel compile)))
         (lt (intersection situations '(:load-toplevel load)))
         (ex (intersection situations '(:execute eval))))
    (cond ((and lt (or ct (and ex compile-time-too)))
           (dolist (c body) (process-toplevel c t)))
          (lt
           (dolist (c body) (process-toplevel c nil)))
          ((or ct (and ex compile-time-too))
           (dolist (c body) (compile-time-eval c))))))

(defun declaration-cst-p (cst)
  (and (cst:consp cst) (eq (cst:raw (cst:first cst)) 'declare)))

(defun process-toplevel-body (cst compile-time-too)
  "LOCALLY, MACROLET and SYMBOL-MACROLET at top level: their body forms are
top-level forms too (CLHS 3.2.3.1), processed in the environment with the
local macros added. A body that starts with declarations is compiled as a
whole instead (the declarations would otherwise be lost)."
  (let* ((form (cst:raw cst))
         (body (if (eq (first form) 'locally)
                   (cst-list (cst:rest cst))
                   (cst-list (cst:rest (cst:rest cst))))))
    (if (and body (declaration-cst-p (first body)))
        (compile-toplevel-form cst compile-time-too)
        (let ((*environment*
                (case (first form)
                  (locally *environment*)
                  (macrolet
                   (let ((env *environment*))
                     (dolist (definition (second form) env)
                       (destructuring-bind (name lambda-list &rest body) definition
                         ;; The expander is evaluated in the environment so
                         ;; far, which holds the enclosing local macros.
                         (let ((expander (cb:eval-cst
                                          *client*
                                          (cst:cst-from-expression
                                           (ecclesia:parse-macro name lambda-list body))
                                          env)))
                           (setf env (trucler:add-local-macro *client* env name expander)))))))
                  (symbol-macrolet
                   (let ((env *environment*))
                     (dolist (binding (second form) env)
                       (setf env (trucler:add-local-symbol-macro
                                  *client* env (first binding) (second binding)))))))))
          (dolist (c body)
            (process-toplevel c compile-time-too))))))

(defun process-toplevel (cst compile-time-too)
  (let ((form (cst:raw cst)))
    (if (and (consp form) (symbolp (first form)))
        (case (first form)
          (progn
            (dolist (c (cst-list (cst:rest cst)))
              (process-toplevel c compile-time-too)))
          (eval-when
           (process-eval-when cst compile-time-too))
          ;; The host reader reads the rest of the file in the package.
          ;; There are no packages at run time yet (M3.3), so nothing is
          ;; compiled for it.
          (in-package
           (setf *package* (or (find-package (second form))
                               (error "IN-PACKAGE: no package named ~S" (second form)))))
          ((locally macrolet symbol-macrolet)
           (process-toplevel-body cst compile-time-too))
          (t
           (multiple-value-bind (expansion macrop) (macroexpand-toplevel form)
             (if macrop
                 (process-toplevel (cst:reconstruct *client* expansion cst) compile-time-too)
                 (compile-toplevel-form cst compile-time-too)))))
        (compile-toplevel-form cst compile-time-too))))

(defstruct (session (:constructor %make-session))
  "Compile-time state shared by the files compiled one after another into
separate modules: the kernel's macros and definitions stay visible to the
programs compiled after it."
  client
  environment
  (defined-functions (make-hash-table :test 'equal)))

(defun make-session ()
  (let ((client (make-instance 'client)))
    (%make-session :client client :environment (make-compile-environment client))))

(defun front-end (paths &optional (session (make-session)))
  "Reads and processes the top-level forms of the files PATHS, in order,
as one compilation unit, in SESSION. Returns the simplified ASTs of the
forms to compile, in order."
  (let* ((*client* (session-client session))
         (cmd:*client* *client*)
         (*environment* (session-environment session))
         (*toplevel-asts* '())
         (*defined-functions* (session-defined-functions session))
         (*referenced-functions* (make-hash-table :test 'equal)))
    ;; Calls to functions defined later in the file are fine: report
    ;; undefined functions at the end (CLHS 3.2.2.3).
    (handler-bind ((cb:no-function-description
                     (lambda (w)
                       (setf (gethash (cb::name w) *referenced-functions*) t)
                       (muffle-warning w))))
      (dolist (path paths)
        (map-file-csts (lambda (cst) (process-toplevel cst nil)) path)))
    (let ((undefined (loop for name being the hash-keys of *referenced-functions*
                           unless (or (gethash name *defined-functions*)
                                      (gethash name *primitives*)
                                      (eq name 'kiln.sys:%primop))
                             collect name)))
      (when undefined
        (warn 'undefined-function-warning :names undefined)))
    (reverse *toplevel-asts*)))
