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

;;; DEFCLASS, DEFGENERIC and DEFMETHOD expand into calls to kiln's
;;; functions in lisp/target/clos/early.lisp, which create the metaobjects
;;; with the early functions during the bootstrap and with the MOP after it
;;; (docs/10 §7). Specializers are passed as designators (a class name or
;;; (EQL object)) so that a DEFMETHOD can be evaluated before the classes
;;; exist.

(defmethod cmd:defclass-compile-time-action
    ((client client) name superclass-names metaclass-name environment)
  (declare (ignore name superclass-names metaclass-name environment))
  nil)

(defmethod cmd:ensure-class-name ((client client))
  'kiln.sys:%defclass)

(defmethod cmd:defgeneric-compile-time-action
    ((client client) name lambda-list argument-precedence-order
     generic-function-class-name method-class-name method-combination-name
     method-combination-arguments documentation-option environment)
  (declare (ignore lambda-list argument-precedence-order
                   generic-function-class-name method-class-name method-combination-name
                   method-combination-arguments documentation-option environment))
  ;; Calls to the generic function are not calls to an undefined function.
  (setf (gethash name *defined-functions*) t)
  nil)

(defmethod cmd:ensure-generic-function
    ((client client) name lambda-list argument-precedence-order
     generic-function-class-name method-class-name method-combination-name
     method-combination-arguments documentation-option environment)
  (declare (ignore environment))
  `(kiln.sys:%defgeneric
    ',name
    :lambda-list ',lambda-list
    ,@(when argument-precedence-order
        `(:argument-precedence-order ',(rest argument-precedence-order)))
    :generic-function-class ',generic-function-class-name
    :method-class ',method-class-name
    :method-combination-name ',method-combination-name
    :method-combination-arguments ',method-combination-arguments
    ,@(when documentation-option
        `(:documentation ',(second documentation-option)))))

(defmethod cmd:make-method-lambda-wrapper ((client client))
  (lambda (lambda-expression)
    (let ((arguments (gensym "ARGUMENTS"))
          (next-methods (gensym "NEXT-METHODS")))
      `(lambda (,arguments ,next-methods)
         (flet ((next-method-p ()
                  (not (null ,next-methods)))
                (call-next-method (&rest arguments)
                  (if (null ,next-methods)
                      (error "no next method")
                      (funcall (kiln.sys:%method-function (first ,next-methods))
                               (or arguments ,arguments)
                               (rest ,next-methods)))))
           (declare (ignorable #'next-method-p #'call-next-method))
           (apply ,lambda-expression ,arguments))))))

(defmethod cmd:ensure-method-wrapper ((client client))
  (lambda (function-name lambda-list qualifiers specializer-designators
           documentation method-lambda)
    `(kiln.sys:%defmethod
      ',function-name
      :lambda-list ',lambda-list
      :qualifiers ',qualifiers
      :specializers (list ,@(loop for s in specializer-designators
                                  collect (if (consp s)
                                              `(list 'eql ,(second s))
                                              `',s)))
      :documentation ',documentation
      :function ,method-lambda)))

;;; Places. Setf expanders live in the compile-time environment
;;; (DEFINE-SETF-EXPANDER registers them at compile time only: there is no
;;; GET-SETF-EXPANSION at run time).

(defmethod cmd:wrap-in-setf-setf-expander ((client client) name function environment)
  (declare (ignore environment))
  `(eval-when (:compile-toplevel)
     (kiln.sys::%define-setf-expander ',name ,function)))

;;; WITH-OUTPUT-TO-STRING with a string: an output stream that appends to
;;; it (Cyclosis' string output stream, docs/10 §16).
(defmethod cmd::output-stream-from-string-function-name ((client client))
  ;; CYCLOSIS is created when the CLOS module's sources are read.
  `(lambda (string)
     (make-instance ',(intern "STRING-OUTPUT-STREAM" "CYCLOSIS") :string string)))

(defmethod cmd:setf-type-function-wrapper ((client client))
  ;; Common-macros' DEFTYPE puts this in an EVAL-WHEN with all three
  ;; situations: the compile-time environment's %DEFTYPE records the
  ;; expander in Clostrum, the kernel's on the symbol.
  (lambda (name function environment)
    (declare (ignore environment))
    `(kiln.sys::%deftype ',name ,function)))

(defmethod cmd:get-setf-expansion ((client client) place &optional environment)
  (let ((environment (or environment *environment*)))
    (cond ((symbolp place)
           (multiple-value-bind (expansion macrop)
               (symbol-macro-expansion client environment place)
             (if macrop
                 (cmd:get-setf-expansion client expansion environment)
                 (call-next-method))))
          ((and (consp place) (symbolp (first place)))
           (let ((expander (clo:setf-expander client
                                              (trucler:global-environment client environment)
                                              (first place))))
             (if expander
                 (funcall expander place environment)
                 (multiple-value-bind (expansion macrop)
                     (let ((*environment* environment))
                       (macroexpand-toplevel place))
                   (if macrop
                       (cmd:get-setf-expansion client expansion environment)
                       (call-next-method))))))
          (t (call-next-method)))))

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

(defvar *host-macros* (make-hash-table :test 'equal)
  "Names of the macros expanded by host functions at compile time.")

(defun host-macro (client genv name function)
  (setf (gethash name *host-macros*) t)
  (setf (clo:macro-function client genv name) function))

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
    ;; A macro whose compile-time expander is the host's (HOST-MACRO) keeps
    ;; it: the target's definition (Khazern's LOOP, Eclector's QUASIQUOTE,
    ;; alexandria's macros) takes effect at load time only. Its expander
    ;; would call functions that exist in the target, not at compile time.
    (def '(setf macro-function)
      (lambda (function name &optional env)
        (declare (ignore env))
        (unless (gethash name *host-macros*)
          (setf (clo:macro-function client genv name) function))
        function))
    ;; DEFINE-COMPILER-MACRO at compile time: ignored (the host's would
    ;; change the host's functions; Common-boot would call its unfinished
    ;; EXPAND-COMPILER-MACRO on those in the environment). The compiler
    ;; does not use compiler macros yet.
    (def 'compiler-macro-function
      (lambda (name &optional env)
        (declare (ignore name env))
        nil))
    (def '(setf compiler-macro-function)
      (lambda (function name &optional env)
        (declare (ignore name env))
        function))
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
    (def 'kiln.sys::%define-setf-expander
      (lambda (name expander)
        (setf (clo:setf-expander client genv name) expander)
        name))
    (def 'get-setf-expansion
      (lambda (place &optional env)
        (cmd:get-setf-expansion client place env)))
    (def 'kiln.sys::%deftype
      (lambda (name expander)
        (setf (clo:type-expander client genv name) expander)
        name))
    ;; DEFCONSTANT's compile-time side (lisp/target/kernel.lisp).
    (def 'kiln.sys::%define-constant
      (lambda (name value)
        (clo:make-constant client genv name value)
        name))
    ;; Expanders may call MACROEXPAND with their &ENVIRONMENT (Predicament's
    ;; RESTART-CASE does).
    (def 'macroexpand-1
      (lambda (form &optional env)
        (compile-time-macroexpand-1 form env)))
    (def 'macroexpand
      (lambda (form &optional env)
        (loop with expanded = nil
              do (multiple-value-bind (expansion macrop)
                     (compile-time-macroexpand-1 form env)
                   (if macrop
                       (setf form expansion expanded t)
                       (return (values form expanded)))))))
    (def 'funcall (lambda (f &rest args) (apply (resolve f) args)))
    (def 'apply (lambda (f &rest args) (apply #'apply (resolve f) args)))))

;;; Libraries written against closer-mop are read with the host's
;;; CLOSER-MOP package, whose symbols mostly belong to the host's MOP
;;; package (SB-MOP). (KILN.SYS::CLOSER-MOP-ALIASES) expands into a call
;;; giving each of those symbols the function and class of the
;;; Clostrophilia (or else CL) symbol of the same name
;;; (lisp/target/clos/closer-mop.lisp).
(defun expand-closer-mop-aliases (form env)
  (declare (ignore form env))
  ;; Clostrophilia does not export all of the MOP (GENERIC-FUNCTION-METHODS
  ;; for instance); names without a definition are skipped at run time.
  (flet ((accessible (name package)
           (multiple-value-bind (symbol status) (find-symbol name package)
             (and status symbol))))
    (let ((pairs '()))
      (do-external-symbols (s '#:closer-mop)
        (let ((target (accessible (symbol-name s) '#:clostrophilia)))
          (when (and target (not (eq target s)))
            (push (cons s target) pairs))))
      `(kiln.sys::%alias-names
        ',(sort pairs #'string< :key (lambda (pair) (symbol-name (car pair))))))))

(defun make-compile-environment (client)
  (let* ((env (cb:create-environment))
         (genv (trucler:global-environment client env)))
    (import-host-functions client genv)
    ;; Eclector reads `X as (ECLECTOR.READER:QUASIQUOTE X); its expansion
    ;; uses only APPEND, LIST and QUOTE. SICL does the same
    ;; (New-boot/Shared/define-backquote-macros.lisp).
    (dolist (name '(eclector.reader:quasiquote eclector.reader:unquote
                    eclector.reader:unquote-splicing))
      (host-macro client genv name (macro-function name)))
    (setf (clo:fdefinition client genv 'eclector.reader::expand)
          (fdefinition 'eclector.reader::expand))
    ;; Ecclesia, for macro expanders such as Clostrophilia's
    ;; DEFINE-METHOD-COMBINATION.
    (do-external-symbols (s '#:ecclesia)
      (when (and (fboundp s) (not (macro-function s)))
        (setf (clo:fdefinition client genv s) (fdefinition s))))
    ;; Cyclosis' macro expanders (streams, docs/10 §16).
    (setf (clo:fdefinition client genv 'alexandria:parse-body)
          (fdefinition 'alexandria:parse-body))
    ;; LOOP is Khazern's, expanded in the host; its expansions use only
    ;; standard operators.
    (host-macro client genv 'loop (macro-function 'khazern-extrinsic:loop))
    (host-macro client genv 'loop-finish (macro-function 'khazern-extrinsic:loop-finish))
    ;; Code evaluated at compile time sees the target's features.
    (clo:make-variable client genv '*features* (copy-list *target-features*))
    ;; DEFSTRUCT is Anatomicl's, expanded in the host (structures.lisp).
    (host-macro client genv 'defstruct #'expand-defstruct)

    (setf (clo:macro-function client genv 'kiln.sys::closer-mop-aliases)
          #'expand-closer-mop-aliases)
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

;;; The READ-ONLY-P argument of LOAD-TIME-VALUE is dropped (it is only a
;;; permission): Common-boot cannot convert it.
(defmethod cb::convert :around ((client client) cst environment)
  (let ((form (cst:raw cst)))
    (if (and (consp form) (eq (first form) 'load-time-value)
             (consp (rest form)) (consp (cddr form)))
        (call-next-method client
                          (cst:reconstruct client (list 'load-time-value (second form)) cst)
                          environment)
        (convert-setq-of-symbol-macros client cst environment #'call-next-method))))

(defun convert-setq-of-symbol-macros (client cst environment next)
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
          (funcall next client (cst:reconstruct client rewritten cst) environment))
        (funcall next))))

;;; Reading

(defparameter *target-features*
  '(:kiln :common-lisp :ansi-cl :64-bit :x86-64 :little-endian
    :ieee-floating-point :unix :linux)
  "The features of the target, for #+ and #- in target sources (not the
host's: an #+SBCL branch must not be read into kiln code).")

;;; Reading target sources: #. evaluates in the compile-time environment.
(defclass source-reader-client (eclector.concrete-syntax-tree::cst-client) ())

(defmethod eclector.reader:evaluate-expression ((client source-reader-client) expression)
  (compile-time-eval (cst:cst-from-expression expression)))

(defvar *source-reader-client* (make-instance 'source-reader-client))

(defun map-file-csts (function path)
  "Reads the forms of PATH one at a time and calls FUNCTION on each CST
before reading the next, so that IN-PACKAGE takes effect for the rest of
the file. Reading starts in KILN-USER, with the target's features."
  (with-open-file (in path)
    (let ((*package* (find-package '#:kiln-user))
          (*read-eval* t)
          (eclector.base:*client* *source-reader-client*))
      (loop with eof = (list nil)
            for cst = (let ((*features* *target-features*))
                        (eclector.concrete-syntax-tree:read in nil eof))
            until (eq cst eof)
            do (funcall function cst)))))

;;; Top-level form processing (CLHS 3.2.3.1)

(defvar *defined-packages*)             ; host packages created by DEFPACKAGE forms
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

(defun compile-time-macroexpand-1 (form env)
  (let ((*environment* (or env *environment*)))
    (if (and (consp form) (symbolp (first form)))
        (multiple-value-bind (expansion macrop) (macroexpand-toplevel form)
          (if macrop (values expansion t) (values form nil)))
        (values form nil))))

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
          ;; Nothing is compiled for it: compiled modules do not change
          ;; *PACKAGE* when they are loaded.
          (in-package
           (setf *package* (or (find-package (second form))
                               (error "IN-PACKAGE: no package named ~S" (second form)))))
          ;; DEFPACKAGE creates the package in the host, so that the rest
          ;; of the sources can be read. Nothing is compiled: the run-time
          ;; package is built from the module's symbol table, which
          ;; mirrors the host package (docs/10 §12). A package that
          ;; exists already (a host system such as Ecclesia) is left
          ;; alone.
          (defpackage
           (unless (find-package (second form))
             (push (eval form) *defined-packages*)))
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
  (defined-functions (make-hash-table :test 'equal))
  ;; DEFSTRUCT layouts and typed structure descriptions (structures.lisp).
  (structures (make-hash-table :test 'equal))
  ;; Host packages described by the symbol tables of the modules compiled
  ;; so far (lower.lisp).
  (packages '()))

(defun make-session ()
  (let ((client (make-instance 'client)))
    (%make-session :client client :environment (make-compile-environment client))))

;;; Iconoclast has no ASTs for FUNCTION and VALUES type specifiers with
;;; arguments, so Common-boot cannot convert declarations that use them.
;;; They are only hints for now: in DECLARE forms, such a type becomes
;;; FUNCTION (or T), and FTYPE declarations are dropped.

(defun compound-function-type-p (type)
  (and (consp type) (member (first type) '(function values))))

(defun simplify-declaration-specifier (spec)
  "SPEC with compound FUNCTION and VALUES types replaced, or NIL to drop it."
  (cond ((atom spec) spec)
        ((eq (first spec) 'ftype) nil)
        ((and (eq (first spec) 'type) (compound-function-type-p (second spec)))
         (list* 'type (if (eq (first (second spec)) 'function) 'function t) (cddr spec)))
        ((compound-function-type-p (first spec))
         (list* 'type (if (eq (first (first spec)) 'function) 'function t) (rest spec)))
        (t spec)))

(defun simplify-declarations (form depth)
  "FORM with its DECLARE forms simplified, or FORM itself if nothing
changes. DEPTH bounds the walk (forms are trees, but data may be cyclic)."
  (cond ((or (atom form) (zerop depth)) form)
        ((and (eq (first form) 'declare) (listp (rest form)))
         (let ((specs (loop for spec in (rest form)
                            for new = (simplify-declaration-specifier spec)
                            when new collect new)))
           (if (equal specs (rest form)) form (cons 'declare specs))))
        ((eq (first form) 'quote) form)
        (t
         (let ((car (simplify-declarations (car form) (1- depth)))
               (cdr (simplify-declarations (cdr form) (1- depth))))
           (if (and (eq car (car form)) (eq cdr (cdr form)))
               form
               (cons car cdr))))))

(defun forget-global-descriptions (environment)
  "Trucler's reference environment caches the descriptions of global
functions and variables it has looked up. The session's environment lives
across files, so the cache would hide later redefinitions (a macro
redefined by a later module, a function that becomes a macro); it is
cleared before each top-level form. At top level the environment holds
nothing else."
  (reinitialize-instance environment :function-description '() :variable-description '()))

(defun front-end (paths &optional (session (make-session)))
  "Reads and processes the top-level forms of the files PATHS (or
(:COMPILE-TIME-TOO path) elements), in order,
as one compilation unit, in SESSION. Returns the simplified ASTs of the
forms to compile, in order, and the host packages that DEFPACKAGE forms
created."
  (let* ((*client* (session-client session))
         (cmd:*client* *client*)
         (*environment* (session-environment session))
         (*toplevel-asts* '())
         (*defined-functions* (session-defined-functions session))
         (*referenced-functions* (make-hash-table :test 'equal))
         (*defined-packages* '())
         (*structures* (session-structures session)))
    ;; Calls to functions defined later in the file are fine: report
    ;; undefined functions at the end (CLHS 3.2.2.3).
    (handler-bind ((cb:no-function-description
                     (lambda (w)
                       (setf (gethash (cb::name w) *referenced-functions*) t)
                       (muffle-warning w))))
      ;; A path (:COMPILE-TIME-TOO path) is processed as if its forms
      ;; were in (EVAL-WHEN (:COMPILE-TOPLEVEL :LOAD-TOPLEVEL :EXECUTE)):
      ;; for the functions that macro expanders call.
      (dolist (path paths)
        (let ((compile-time-too (and (consp path) (eq (first path) :compile-time-too))))
          (map-file-csts (lambda (cst)
                           (forget-global-descriptions *environment*)
                           (let* ((raw (cst:raw cst))
                                  (simplified (simplify-declarations raw 10000)))
                             (unless (eq simplified raw)
                               (setf cst (cst:reconstruct *client* simplified cst))))
                           (process-toplevel cst compile-time-too))
                         (if compile-time-too (second path) path)))))
    (let ((undefined (loop for name being the hash-keys of *referenced-functions*
                           unless (or (gethash name *defined-functions*)
                                      (gethash name *primitives*)
                                      (eq name 'kiln.sys:%primop))
                             collect name)))
      (when undefined
        (warn 'undefined-function-warning :names undefined)))
    (values (reverse *toplevel-asts*) (reverse *defined-packages*))))
