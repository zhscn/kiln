(in-package #:kiln.compiler)

;;;; Front end (M2): Eclector reads CSTs; top-level forms are processed
;;;; here as in COMPILE-FILE (CLHS 3.2.3.1); Common-boot turns each form to
;;;; be compiled into an Iconoclast AST, which SIMPLIFY-AST reduces to the
;;;; subset that lower.lisp translates to KIR. See docs/08-m2-front-end.md.
;;;;
;;;; This file is the compiler's in the host (SBCL) and on kiln (the
;;;; compiler module, docs/11 §8): what differs is in host.lisp and
;;;; lisp/target/compiler/client.lisp, loaded after it, and in a few #+KILN
;;;; branches here. In the host, compile-time evaluation (EVAL-WHEN
;;;; :COMPILE-TOPLEVEL, macro definitions, DEFVAR proclamations) runs
;;;; through Common-boot's HIR evaluator, in a Clostrum environment that
;;;; holds the compile-time definitions; on kiln, the compile-time
;;;; environment is the run-time one, and Maclina evaluates.

(defclass client (#-kiln kiln.macros:macro-client
                  #+kiln kiln.macros-target:macro-client
                  trucler-reference:client)
  ()
  (:documentation "The front end's client. CROSS-CLIENT (cross.lisp) compiles
in a compile-time environment of its own: SBCL's, and kiln's when it
compiles kiln (M5.4). On kiln, IMAGE-CLIENT
(lisp/target/compiler/client.lisp) compiles in the running image, as
COMPILE-FILE does."))

(defgeneric make-compile-environment (client))

(defgeneric initialize-session (client session)
  (:method (client session)
    (declare (ignore client))
    session))

(defmethod cb:convert-with-parser-p ((client client) operator)
  (special-operator-p operator))

(defvar *client*)
(defvar *defined-functions*)            ; names defined by DEFUN in this file
(defvar *referenced-functions*)         ; undefined names seen by Common-boot
(defvar *toplevel-environment*)          ; Trucler environment of the top level
(defvar *package-renames* '()
  "Alist (NAME . NEW-NAME) of package names (strings): the file being
processed names the package NAME, but its forms are read in NEW-NAME (a
target library whose package has the name of a host one, docs/11 §3).
Their definitions of macros that exist at compile time take effect at load
time only.")


;;; Compile-time actions of Common-macros' DEFUN and DEFGENERIC: calls to
;;; the function are not calls to an undefined function.
(defmethod #-kiln cmd:defun-compile-time-action #+kiln kiln.cmd:defun-compile-time-action
    ((client client) name lambda-list environment)
  (declare (ignore lambda-list environment))
  (setf (gethash name *defined-functions*) t)
  nil)

(defmethod #-kiln cmd:defgeneric-compile-time-action #+kiln kiln.cmd:defgeneric-compile-time-action
    ((client client) name lambda-list argument-precedence-order
     generic-function-class-name method-class-name method-combination-name
     method-combination-arguments documentation-option environment)
  (declare (ignore lambda-list argument-precedence-order
                   generic-function-class-name method-class-name method-combination-name
                   method-combination-arguments documentation-option environment))
  (setf (gethash name *defined-functions*) t)
  nil)

(define-condition undefined-function-warning (style-warning)
  ((names :initarg :names :reader undefined-function-names))
  (:report (lambda (c s)
             (format s "undefined function~P: ~{~S~^, ~}"
                     (length (undefined-function-names c))
                     (undefined-function-names c)))))
(defvar *environment*)                  ; Trucler environment
(defvar *structures*)                   ; DEFSTRUCT layouts (structures.lisp)

(defun global-environment ()
  (trucler:global-environment *client* *environment*))

;;; Inline functions (docs/08 §8). (DECLAIM (INLINE F)) before
;;; (DEFUN F ...) at top level makes calls of F that refer to the global
;;; function open-coded: (F A B) is converted as
;;; (LET ((X A) (Y B)) (BLOCK F ...)). Only functions whose lambda lists
;;; have required parameters only, defined in the null lexical environment,
;;; are expanded. A call is not expanded inside the expansion of the same
;;; function, where a local NOTINLINE declaration applies, or where a local
;;; function, macro or symbol macro shadows a name the body uses.

(defvar *inline-functions*)
(defvar *inline-expanding* '()
  "The inline functions whose expansions are being converted.")
(defvar *inline-enabled* nil
  "True while forms are converted for the target. Calls are not expanded
in code that runs at compile time (EVAL-CST, the expanders of local
macros): an expansion can use the kernel's internals.")

(defmethod cb:eval-cst :around ((client client) cst environment)
  (declare (ignore cst environment))
  (let ((*inline-enabled* nil))
    (call-next-method)))

(defmethod cb::finalize-local-macro-ast :around ((client client) ast environment)
  (declare (ignore ast environment))
  (let ((*inline-enabled* nil))
    (call-next-method)))

(defvar *local-notinline* '()
  "Names declared NOTINLINE by the forms being converted.")

(defun local-notinline-names (form)
  "The names that the declarations at the head of the body of FORM (a
LAMBDA, LET, LOCALLY ... form) declare NOTINLINE. Such a declaration is
taken to cover the whole form: not expanding a call is always correct."
  (and (consp form)
       (member (first form) '(lambda let let* locally flet labels macrolet symbol-macrolet
                              multiple-value-bind destructuring-bind))
       (let ((body (if (eq (first form) 'locally) (rest form) (and (consp (rest form))
                                                                     (cddr form)))))
         (loop for item in (if (listp body) body '())
               while (or (stringp item) (and (consp item) (eq (first item) 'declare)))
               when (consp item)
                 append (loop for spec in (rest item)
                              when (and (consp spec) (eq (first spec) 'notinline))
                                append (remove-if-not #'symbolp (rest spec)))))))

(defun note-inline-proclamation (kind names)
  (when (boundp '*inline-functions*)
    (dolist (name names)
      (when (or (symbolp name) (setf-function-name-p name))
        (if (eq kind 'notinline)
            (setf (gethash name *inline-functions*) :notinline)
            (unless (consp (gethash name *inline-functions*))
              (setf (gethash name *inline-functions*) :inline)))))))

(defun split-body (body)
  "The declarations (and documentation) of BODY, and its forms."
  (loop with declarations = '()
        for (form . more) on body
        do (cond ((and (consp form) (eq (first form) 'declare))
                  (push form declarations))
                 ((and (stringp form) more))
                 (t (return (values (reverse declarations) (cons form more)))))
        finally (return (values (reverse declarations) '()))))

(defun tree-symbols (tree)
  (let ((symbols '()) (seen (make-hash-table :test 'eq)))
    (labels ((walk (x)
               (cond ((symbolp x) (pushnew x symbols))
                     ((atom x))
                     ((gethash x seen))
                     (t (setf (gethash x seen) t)
                        (walk (car x)) (walk (cdr x))))))
      (walk tree))
    symbols))

(defun setf-function-name-p (name)
  (and (consp name) (eq (first name) 'setf) (consp (rest name))
       (symbolp (second name)) (null (cddr name))))

(defun note-inline-definition (form)
  "FORM is a top-level DEFUN: keep its body if its name is declared inline."
  (destructuring-bind (name lambda-list &rest body) (rest form)
    (when (and (or (symbolp name) (setf-function-name-p name))
               ;; Declared inline, or inline and defined before: the new
               ;; definition replaces the expansion.
               (let ((entry (gethash name *inline-functions*)))
                 (or (eq entry :inline) (consp entry)))
               (eq *environment* *toplevel-environment*)
               (listp lambda-list)
               (every #'symbolp lambda-list)
               (notany (lambda (p) (member p lambda-list-keywords)) lambda-list))
      (multiple-value-bind (declarations forms) (split-body body)
        (setf (gethash name *inline-functions*)
              (list lambda-list declarations
                    `(block ,(if (symbolp name) name (second name)) ,@forms)
                    (tree-symbols body)))))))

(defun inline-call (form)
  "The function name and the argument forms of FORM, a call by name:
(F ARG...), or (FUNCALL (FUNCTION (SETF F)) ARG...) as SETF of a place
expands into; else NIL."
  (cond ((and (consp form) (symbolp (first form)) (listp (rest form)))
         (values (first form) (rest form)))
        ((and (consp form) (eq (first form) 'funcall)
              (consp (rest form)) (listp (cddr form))
              (consp (second form)) (eq (first (second form)) 'function)
              (consp (rest (second form))) (null (cddr (second form)))
              (setf-function-name-p (second (second form))))
         (values (second (second form)) (cddr form)))
        (t nil)))

(defun inline-call-p (client environment form)
  (multiple-value-bind (name arguments) (inline-call form)
   (and *inline-enabled*
       name
       (let ((entry (and (boundp '*inline-functions*)
                         (gethash name *inline-functions*))))
         (and (consp entry)
              (not (member name *inline-expanding* :test #'equal))
              (not (member name *local-notinline* :test #'equal))
              (< (length *inline-expanding*) 8)
              (handler-case (= (length arguments) (length (first entry)))
                (error () nil))
              (let ((description (trucler:describe-function client environment name)))
                ;; NIL: a function unknown to the compile-time
                ;; environment (DEFUN does not define it at compile time).
                (or (null description)
                    (and (typep description 'trucler:global-function-description)
                         (not (eq (ignore-errors (trucler:inline description))
                                  'notinline)))))
              (notany (lambda (symbol)
                        (or (typep (trucler:describe-function client environment symbol)
                                   '(or trucler:local-function-description
                                     trucler:local-macro-description))
                            (typep (trucler:describe-variable client environment symbol)
                                   'trucler:local-symbol-macro-description)))
                      (fourth entry)))))))

(defun inline-expansion (form)
  (multiple-value-bind (name arguments) (inline-call form)
    (destructuring-bind (lambda-list declarations body &rest more)
        (gethash name *inline-functions*)
      (declare (ignore more))
      `(let ,(mapcar #'list lambda-list arguments)
         ,@declarations
         ,body))))

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

;;; Before Common-boot converts a form: calls of inline functions are
;;; expanded (unless a NOTINLINE declaration of the form covers them);
;;; the READ-ONLY-P argument of LOAD-TIME-VALUE is dropped (it is only a
;;; permission): Common-boot cannot convert it; SETQ of symbol macros
;;; becomes SETF.
(defmethod cb::convert :around ((client client) cst environment)
  (let ((form (cst:raw cst)))
    (let ((names (local-notinline-names form)))
      (when names
        (return-from cb::convert
          (let ((*local-notinline* (append names *local-notinline*)))
            (convert-maybe-inline client cst environment form #'call-next-method)))))
    (convert-maybe-inline client cst environment form #'call-next-method)))

(defun convert-maybe-inline (client cst environment form next)
  (when (inline-call-p client environment form)
    (return-from convert-maybe-inline
      (let ((*inline-expanding* (cons (inline-call form) *inline-expanding*)))
        (funcall next client (cst:reconstruct client (inline-expansion form) cst) environment))))
  (let ((expansion (compiler-macro-expansion client environment form)))
    (when expansion
      (return-from convert-maybe-inline
        (funcall next client (cst:reconstruct client expansion cst) environment))))
  (convert-load-time-value client cst environment form next))

;;; Compiler macros: kiln has none of its own yet, but the host's of the
;;; libraries whose macros are the host's (USE-HOST-MACROS, cross.lisp)
;;; apply to the code compiled for the target (parser.packrat's PARSE
;;; compiles constant grammar expressions when it expands, docs/11 §9).
(defgeneric client-compiler-macro (client name)
  (:method (client name)
    (declare (ignore client name))
    nil))

(defun compiler-macro-expansion (client environment form)
  "The expansion of FORM, a call of a global function, by its compiler
macro, or NIL (none, or the compiler macro declines)."
  (and *inline-enabled*
       (consp form) (symbolp (first form))
       (let ((expander (client-compiler-macro client (first form))))
         (and expander
              (typep (trucler:describe-function client environment (first form))
                     '(or null trucler:global-function-description))
              (let ((expansion (funcall expander form environment)))
                (and (not (eq expansion form)) expansion))))))

(defun convert-load-time-value (client cst environment form next)
  (cond ((and (consp form) (eq (first form) 'load-time-value)
              (consp (rest form)) (consp (cddr form)))
         (funcall next client
                  (cst:reconstruct client (list 'load-time-value (second form)) cst)
                  environment))
        ;; (THE (VALUES ...) X) and (THE (FUNCTION ...) X): Iconoclast has
        ;; no ASTs for these types (SIMPLIFY-DECLARATION-SPECIFIER).
        ((and (consp form) (eq (first form) 'the) (consp (rest form))
              (compound-function-type-p (second form)) (consp (cddr form)))
         (funcall next client
                  (cst:reconstruct client
                                   (list 'the
                                         (if (eq (first (second form)) 'function) 'function t)
                                         (third form))
                                   cst)
                  environment))
        (t
         (convert-setq-of-symbol-macros client cst environment next))))

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
    (let ((*package* (find-package #-kiln '#:kiln-user #+kiln '#:common-lisp-user))
          (*read-eval* t)
          (eclector.base:*client* *source-reader-client*))
      (loop with eof = (list nil)
            for cst = (let ((*features* *target-features*))
                        (eclector.concrete-syntax-tree:read in nil eof))
            until (eq cst eof)
            do (funcall function cst)))))

;;; Top-level form processing (CLHS 3.2.3.1)

(defvar *defined-packages*)             ; host packages created by DEFPACKAGE forms
(defvar *toplevel-asts*)                ; TOPLEVEL-FORMs (lower.lisp), most recent first

;;; Where the top-level form being processed comes from, for the debug
;;; information of the functions compiled from it (docs/17).
(defvar *source-file* nil)              ; the file's name (one string per file), or NIL
(defvar *toplevel-source* nil)          ; (START . END) of the outermost form, or NIL
(defvar *definition-name* nil)          ; DEFINITION-NAME of the innermost definition form

(defun cst-source-range (cst)
  "The source range (START . END) of CST if it has one."
  (let ((source (cst:source cst)))
    (and (consp source) (integerp (car source)) (integerp (cdr source)) source)))

(defun method-specializers (lambda-list)
  (loop for p in lambda-list
        until (member p lambda-list-keywords)
        collect (if (consp p) (second p) t)))

(defun definition-name (form)
  "For a definition FORM (a DEF... form), the name under which backtraces
show what it defines; for DEFUN, DEFMACRO, DEFMETHOD, DEFGENERIC and
DEFINE-COMPILER-MACRO the name of the function it defines, and true as
the second value."
  (when (and (consp form) (symbolp (first form)) (consp (rest form)))
    (let ((op (first form)) (name (second form)))
      (case op
        ((defun defgeneric) (values name t))
        (defmacro (values `(macro-function ,name) t))
        (define-compiler-macro (values `(compiler-macro ,name) t))
        (defmethod
         (let ((qualifiers (loop for x in (cddr form) until (listp x) collect x))
               (lambda-list (find-if #'listp (cddr form))))
           (values `(method ,name ,@qualifiers ,(method-specializers lambda-list)) t)))
        (t
         (and (symbolp op)
              (> (length (symbol-name op)) 3)
              (string= "DEF" (symbol-name op) :end2 3)
              (or (symbolp name) (and (consp name) (eq (first name) 'setf)))
              (values (list op name) nil)))))))

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
  (push (make-toplevel-form (simplify (let ((*inline-enabled* t))
                                        (cb:cst-to-ast *client* cst *environment*)))
                            *source-file* *toplevel-source* *definition-name*)
        *toplevel-asts*))

(defun macroexpand-toplevel (form)
  "Returns the expansion of FORM and true if FORM is a macro form."
  (let ((op (first form)))
    (cond ((special-operator-p op) (values nil nil))
          (t
           (let ((description (trucler:describe-function *client* *environment* op)))
             (cond ((and (typep description 'trucler:macro-description)
                         #-kiln (not (eq op 'defmacro)))
                    (values (funcall (trucler:expander description) form *environment*) t))
                   #-kiln
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

(defvar *file-sets-package*)             ; an IN-PACKAGE in this file sets *PACKAGE*

(defun find-package-function ()
  "Parcl's FIND-PACKAGE-OR-ERROR (the package exists once the CLOS module's
sources have been read)."
  (and (find-package '#:parcl) (find-symbol "FIND-PACKAGE-OR-ERROR" '#:parcl)))

(defgeneric run-time-packages-p (client)
  (:documentation "True if the package system has been compiled (the CLOS
module).")
  (:method (client)
    (declare (ignore client))
    (let ((name (find-package-function)))
      (and name (gethash name *defined-functions*)))))

(defun renamed-package-name (designator)
  (let ((entry (assoc (string designator) *package-renames* :test #'string=)))
    (if entry (cdr entry) (string designator))))

(defun process-toplevel (cst compile-time-too)
  (let* ((form (cst:raw cst))
         (*definition-name* (multiple-value-bind (name function-p) (definition-name form)
                              (if name (cons name function-p) *definition-name*))))
    (when (and (consp form) (eq (first form) 'defun) (consp (rest form)) (consp (cddr form)))
      (note-inline-definition form))
    (if (and (consp form) (symbolp (first form)))
        (case (first form)
          (progn
            (dolist (c (cst-list (cst:rest cst)))
              (process-toplevel c compile-time-too)))
          (eval-when
           (process-eval-when cst compile-time-too))
          ;; The host reader reads the rest of the file in the package.
          ;; Once the package system exists at run time, *PACKAGE* is
          ;; set at load time too, as LOAD would (code run at load time
          ;; uses it: Iconoclast EXPORTs), and reset to CL-USER at the end
          ;; of the file (FRONT-END).
          (in-package
           (setf *package* (or (find-package (renamed-package-name (second form)))
                               (error "IN-PACKAGE: no package named ~S" (second form))))
           (when (run-time-packages-p *client*)
             (setf *file-sets-package* t)
             (compile-toplevel-form
              (cst:cst-from-expression
               `(setq *package* (,(find-package-function)
                                 ',(package-name *package*))))
              nil)))
          ;; DEFPACKAGE creates the package in the host, so that the rest
          ;; of the sources can be read. Nothing is compiled: the run-time
          ;; package is built from the module's symbol table, which
          ;; mirrors the host package (docs/10 §12). A package that
          ;; exists already (a host system such as Ecclesia) is left
          ;; alone, but it is a package of the module too: its external
          ;; symbols are in the module whichever host compiles it (on
          ;; kiln, every package of kiln's sources exists).
          (defpackage
           (let ((name (renamed-package-name (second form))))
             (pushnew (or (find-package name)
                          (eval `(defpackage ,name ,@(cddr form))))
                      *defined-packages*)))
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
  (packages '())
  ;; Inline proclamations and expansions (*INLINE-FUNCTIONS*).
  ;; Keys are function names: symbols and (SETF symbol).
  (inline-functions (make-hash-table :test 'equal)))

(defun make-session (&key (client-class #-kiln 'cross-client #+kiln 'image-client))
  "A session whose client is an instance of CLIENT-CLASS: CROSS-CLIENT, or
on kiln IMAGE-CLIENT (the default there)."
  (let* ((client (make-instance client-class))
         (session (%make-session :client client
                                 :environment (make-compile-environment client))))
    (initialize-session client session)))

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

(defvar *trace-toplevel* nil
  "True: FRONT-END prints each file and the head of each top-level form
to *ERROR-OUTPUT*, for finding the form that an error comes from.")

(defun front-end (paths &optional (session (make-session)))
  "Reads and processes the top-level forms of the files PATHS (or
(:COMPILE-TIME-TOO path) elements), in order,
as one compilation unit, in SESSION. Returns the simplified ASTs of the
forms to compile, in order, and the host packages that DEFPACKAGE forms
created."
  (call-with-front-end
   session
   (lambda ()
     ;; A path (:COMPILE-TIME-TOO path) is processed as if its forms
     ;; were in (EVAL-WHEN (:COMPILE-TOPLEVEL :LOAD-TOPLEVEL :EXECUTE)):
     ;; for the functions that macro expanders call.
     ;; (:RENAMES alist path) reads the file with *PACKAGE-RENAMES*.
     (dolist (path paths)
       (let ((compile-time-too (and (consp path) (eq (first path) :compile-time-too)))
             (*package-renames* (if (and (consp path) (eq (first path) :renames))
                                    (second path)
                                    '()))
             (*file-sets-package* nil)
             (*source-file* (let ((file (if (consp path) (car (last path)) path)))
                              (if (stringp file) file (namestring file)))))
         (when *trace-toplevel*
           (format *error-output* "~&~A~%" (if (consp path) (car (last path)) path)))
         (map-file-csts (lambda (cst) (process-toplevel-cst cst compile-time-too))
                        (if (consp path) (car (last path)) path))
         (when *file-sets-package*
           (compile-toplevel-form
            (cst:cst-from-expression
             `(setq *package* (,(find-package-function) "COMMON-LISP-USER")))
            nil)))))))

(defun front-end-forms (forms &optional (session (make-session)))
  "As FRONT-END, for the top-level FORMS (for COMPILE, docs/11 §11)."
  (call-with-front-end
   session
   (lambda ()
     (let ((*package-renames* '())
           (*file-sets-package* nil))
       (dolist (form forms)
         (process-toplevel-cst (cst:cst-from-expression form) nil))))))

(defun process-toplevel-cst (cst compile-time-too)
  (forget-global-descriptions *environment*)
  (when *trace-toplevel*
    (let ((raw (cst:raw cst)))
      (format *error-output* "~&  ~S~@[ ~S~]~%"
              (if (consp raw) (first raw) raw)
              (and (consp raw) (consp (rest raw))
                   (atom (second raw)) (second raw)))))
  (let* ((raw (cst:raw cst))
         (simplified (simplify-declarations raw 10000)))
    (unless (eq simplified raw)
      (setf cst (cst:reconstruct *client* simplified cst))))
  ;; As SBCL's COMPILE-FILE: gensyms are numbered from 0 in each
  ;; top-level form. COMPILE-MODULE names those in constants by their
  ;; order in the module (MODULE-SYMBOL-NAME).
  (let ((*gensym-counter* 0)
        (*toplevel-source* (cst-source-range cst))
        (*definition-name* nil))
    (process-toplevel cst compile-time-too)))

(defun call-with-front-end (session thunk)
  "Calls THUNK, which processes top-level forms, with the front end's state
bound for SESSION. Returns the simplified ASTs of the forms to compile, in
order, and the host packages that DEFPACKAGE forms created."
  (let* ((*client* (session-client session))
         (#-kiln cmd:*client* #+kiln kiln.cmd:*client* *client*)
         (*environment* (session-environment session))
         (*toplevel-asts* '())
         (*defined-functions* (session-defined-functions session))
         (*referenced-functions* (make-hash-table :test 'equal))
         (*defined-packages* '())
         (*structures* (session-structures session))
         (*inline-functions* (session-inline-functions session))
         (*toplevel-environment* *environment*))
    ;; Calls to functions defined later in the file are fine: report
    ;; undefined functions at the end (CLHS 3.2.2.3).
    (handler-bind ((cb:no-function-description
                     (lambda (w)
                       (setf (gethash (cb::name w) *referenced-functions*) t)
                       (muffle-warning w))))
      (funcall thunk))
    (let ((undefined (loop for name being the hash-keys of *referenced-functions*
                           unless (or (gethash name *defined-functions*)
                                      (gethash name *primitives*)
                                      (eq name 'kiln.sys:%primop))
                             collect name)))
      (when undefined
        (warn 'undefined-function-warning :names undefined)))
    (values (reverse *toplevel-asts*) (reverse *defined-packages*))))
