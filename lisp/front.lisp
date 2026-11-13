(in-package #:kiln.compiler)

;;;; Front end (M2): Eclector reads CSTs; top-level forms are processed
;;;; here as in COMPILE-FILE (CLHS 3.2.3.1); each form to be compiled is
;;;; converted to HIR (lisp/hir/convert.lisp), which lisp/hir/lower.lisp
;;;; translates to KIR.
;;;;
;;;; This file is the compiler's in the host (SBCL) and on kiln (the
;;;; compiler module): what differs is in cross.lisp and
;;;; lisp/target/compiler/client.lisp, loaded after it, and in a few #+KILN
;;;; branches here. In cross compilation, compile-time evaluation
;;;; (EVAL-WHEN :COMPILE-TOPLEVEL, macro definitions, DEFVAR proclamations)
;;;; runs through the HIR evaluator (lisp/hir/eval.lisp), in a Clostrum
;;;; environment that holds the compile-time definitions; compiling into
;;;; the image on kiln, the compile-time environment is the run-time one,
;;;; and the HIR evaluator executes.

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

(defvar *client*)
(defvar *defined-functions*)            ; names defined by DEFUN in this file
(defvar *referenced-functions*)         ; undefined names seen by the converter
(defvar *toplevel-environment*)          ; Trucler environment of the top level
(defvar *package-renames* '()
  "Alist (NAME . NEW-NAME) of package names (strings): the file being
processed names the package NAME, but its forms are read in NEW-NAME (a
target library whose package has the name of a host one).
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
(define-condition undefined-variable-warning (warning)
  ((name :initarg :name :reader undefined-variable-name))
  (:report (lambda (condition stream)
             (format stream "Undefined variable: ~S" (undefined-variable-name condition)))))

(defvar *referenced-variables* nil)

(define-condition unknown-declaration-warning (style-warning)
  ((specifier :initarg :specifier :reader unknown-declaration-specifier))
  (:report (lambda (condition stream)
             (format stream "Unrecognized declaration ~S"
                     (unknown-declaration-specifier condition)))))

(defvar *environment*)                  ; Trucler environment
(defvar *structures*)                   ; DEFSTRUCT layouts (structures.lisp)

;;; Dependency tracking. While a definition is compiled in the
;;; image (lisp/target/compiler/dependencies.lisp), *DEPENDENCIES* is a
;;; cons whose cdr collects the keys (KIND NAME) of the definitions its
;;; code depends on at compile time: (:MACRO name) for a global macro
;;; expanded (or a name not defined when the code was compiled),
;;; (:INLINE name), (:SETF name) for a place, (:CONSTANT name). Elsewhere
;;; (cross compilation) it is NIL.

(defvar *dependencies* nil)
(defvar *dependency-query-hook* nil)

(defun prepare-dependency (kind name)
  (when *dependency-query-hook*
    (funcall *dependency-query-hook* (list kind name))))

(defun note-dependency (kind name)
  (prepare-dependency kind name)
  (let ((cell *dependencies*))
    (when (and cell
               (let ((symbol (if (consp name) (second name) name)))
                 (and (symbolp symbol)
                      (not (eq (symbol-package symbol) (find-package '#:common-lisp)))
                      (not (keywordp symbol)))))
      (let ((key (list kind name)))
        (unless (member key (cdr cell) :test #'equal)
          (push key (cdr cell)))))))

(defgeneric compiles-into-image-p (client)
  (:documentation "True if CLIENT compiles code for the running image, whose
compile-time definitions are the image's (IMAGE-CLIENT).")
  (:method (client)
    (declare (ignore client))
    nil))

(defun note-redefined (kind name)
  "The definition (KIND NAME) changed at compile time: the code compiled
in the image that depends on it is out of date."
  #+kiln (when (compiles-into-image-p *client*)
           (kiln.kernel::change-assumption kind name))
  #-kiln (declare (ignore kind name)))

;;; Inline functions. (DECLAIM (INLINE F)) before
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
in code that runs at compile time (compile-time evaluation, the expanders
of local macros): an expansion can use the kernel's internals.")

(defvar *local-notinline* '()
  "Names declared NOTINLINE by the forms being converted.")

(defun note-inline-proclamation (kind names)
  (when (boundp '*inline-functions*)
    (dolist (name names)
      (when (or (symbolp name) (setf-function-name-p name))
        (if (eq kind 'notinline)
            (progn
              (when (consp (gethash name *inline-functions*))
                (note-redefined :inline name))
              (setf (gethash name *inline-functions*) :notinline))
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
  (let ((symbols '()) (seen nil))
    (labels ((walk (x depth)
               (cond ((and (symbolp x) (symbol-package x)
                           (not (keywordp x)) (not (member x '(nil t))))
                      (pushnew x symbols :test #'eq))
                     ((or (atom x) (zerop depth)))
                     ((and (< depth 99900)
                           (let ((s (or seen (setf seen (make-hash-table :test 'eq)))))
                             (or (gethash x s) (progn (setf (gethash x s) t) nil)))))
                     (t (walk (car x) (1- depth))
                        (walk (cdr x) (1- depth))))))
      (walk tree 100000))
    symbols))

(defun setf-function-name-p (name)
  (and (consp name) (eq (first name) 'setf) (consp (rest name))
       (symbolp (second name)) (null (cddr name))))

(defun parse-inline-lambda-list (lambda-list)
  "Parses LAMBDA-LIST for inlining. Returns (LIST REQUIRED OPTIONAL KEYS KEY-P)
where REQUIRED is a list of symbols, OPTIONAL is a list of (VAR INITFORM),
and KEYS is a list of (KEYWORD VAR INITFORM); or NIL if LAMBDA-LIST is not
eligible for inlining."
  (when (hir-proper-list-p lambda-list)
    (let ((state :required) (required '()) (optional '()) (keys '()) (keyp nil))
      (dolist (item lambda-list
               (list (nreverse required) (nreverse optional) (nreverse keys) keyp))
        (cond ((eq item '&optional)
               (unless (eq state :required) (return nil))
               (setf state :optional))
              ((eq item '&key)
               (unless (member state '(:required :optional)) (return nil))
               (setf state :key keyp t))
              ((member item lambda-list-keywords)
               (return nil))
              ((eq state :required)
               (unless (and (symbolp item) item) (return nil))
               (push item required))
              ((eq state :optional)
               (cond ((and (symbolp item) item)
                      (push (list item nil) optional))
                     ((and (consp item) (symbolp (first item)) (first item)
                           (or (null (rest item))
                               (and (consp (rest item)) (null (cddr item)))))
                      (push (list (first item) (second item)) optional))
                     (t (return nil))))
              ((eq state :key)
               (cond ((and (symbolp item) item)
                      (push (list (intern (symbol-name item) '#:keyword) item nil) keys))
                     ((and (consp item)
                           (or (null (rest item))
                               (and (consp (rest item)) (null (cddr item)))))
                      (let ((head (first item)) (init (second item)))
                        (cond ((and (symbolp head) head)
                               (push (list (intern (symbol-name head) '#:keyword) head init) keys))
                              ((and (consp head) (symbolp (first head)) (first head)
                                    (consp (rest head)) (symbolp (second head)) (second head)
                                    (null (cddr head)))
                               (push (list (first head) (second head) init) keys))
                              (t (return nil)))))
                     (t (return nil)))))))))

(defun inline-arguments-valid-p (parsed arguments)
  (and (hir-proper-list-p arguments)
       (destructuring-bind (required optional keys keyp) parsed
         (let ((n (length arguments))
               (nreq (length required))
               (nopt (length optional)))
           (and (>= n nreq)
                (if (not keyp)
                    (<= n (+ nreq nopt))
                    (let ((rest (nthcdr (+ nreq nopt) arguments)))
                      (and (evenp (length rest))
                           (loop for (k nil) on rest by #'cddr
                                 always (and (keywordp k)
                                             (assoc k keys :test #'eq)))))))))))

(defun note-inline-definition (form)
  "FORM is a top-level DEFUN: keep its body if its name is declared inline."
  (destructuring-bind (name lambda-list &rest body) (rest form)
    (let ((parsed (and (or (symbolp name) (setf-function-name-p name))
                       ;; Declared inline, or inline and defined before: the new
                       ;; definition replaces the expansion.
                       (let ((entry (gethash name *inline-functions*)))
                         (or (eq entry :inline) (consp entry)))
                       (eq *environment* *toplevel-environment*)
                       (parse-inline-lambda-list lambda-list))))
      (when parsed
        (multiple-value-bind (declarations forms) (split-body body)
          (when (consp (gethash name *inline-functions*))
            (note-redefined :inline name))
          (setf (gethash name *inline-functions*)
                (list parsed declarations
                      `(block ,(if (symbolp name) name (second name)) ,@forms)
                      (tree-symbols (cons lambda-list body)))))))))

(defun inline-call (form)
  "The function name and the argument forms of FORM, a call by name:
(F ARG...), or (FUNCALL (FUNCTION (SETF F)) ARG...) as SETF of a place
expands into; else NIL."
  (cond ((and (consp form) (eq (first form) 'funcall)
              (consp (rest form)) (listp (cddr form))
              (consp (second form)) (eq (first (second form)) 'function)
              (consp (rest (second form))) (null (cddr (second form)))
              (setf-function-name-p (second (second form))))
         (values (second (second form)) (cddr form)))
        ((and (consp form) (symbolp (first form)) (listp (rest form)))
         (values (first form) (rest form)))
        (t nil)))

(defun local-shadowed-p (client environment symbols)
  "True if any symbol in SYMBOLS has a local function, local macro, or
local symbol-macro binding in ENVIRONMENT."
  (when symbols
    (loop for env = environment then (hir-env-parent env)
          while (hir-env-p env)
          do (dolist (entry (hir-env-funcs env))
               (when (and (symbolp (car entry))
                          (member (car entry) symbols :test #'eq))
                 (return-from local-shadowed-p t)))
             (dolist (entry (hir-env-vars env))
               (when (and (consp (cdr entry))
                          (eq (cadr entry) :symbol-macro)
                          (member (car entry) symbols :test #'eq))
                 (return-from local-shadowed-p t))))
    (let ((base (if (hir-env-p environment) (hir-env-base environment) environment))
          (*dependencies* nil))
      (if (typep base 'trucler-reference:environment)
          (or (loop for d in (trucler-reference::function-description base)
                    thereis (and (typep d '(or trucler:local-function-description
                                              trucler:local-macro-description))
                                 (member (trucler:name d) symbols :test #'eq)))
              (loop for d in (trucler-reference::variable-description base)
                    thereis (and (typep d 'trucler:local-symbol-macro-description)
                                 (member (trucler:name d) symbols :test #'eq))))
          (loop for symbol in symbols
                thereis (or (typep (trucler:describe-function client base symbol)
                                   '(or trucler:local-function-description
                                     trucler:local-macro-description))
                            (typep (trucler:describe-variable client base symbol)
                                   'trucler:local-symbol-macro-description)))))))

(defun inline-call-p (client environment form)
  (multiple-value-bind (name arguments) (inline-call form)
   (and *inline-enabled*
       (hir-policy-optimize-p *hir-policy*)
       name
       (let ((entry (and (boundp '*inline-functions*)
                         (gethash name *inline-functions*))))
         (and (consp entry)
              (not (member name *inline-expanding* :test #'equal))
              (not (member name *local-notinline* :test #'equal))
              (< (length *inline-expanding*) 8)
              (inline-arguments-valid-p (first entry) arguments)
              (let ((description (trucler:describe-function client environment name)))
                ;; NIL: a function unknown to the compile-time
                ;; environment (DEFUN does not define it at compile time).
                (or (null description)
                    (and (typep description 'trucler:global-function-description)
                         (not (eq (ignore-errors (trucler:inline description))
                                  'notinline)))))
              (not (local-shadowed-p client environment (fourth entry))))))))

(defun inline-expansion (form)
  (multiple-value-bind (name arguments) (inline-call form)
    (destructuring-bind (parsed declarations body &rest more)
        (gethash name *inline-functions*)
      (declare (ignore more))
      (destructuring-bind (required optional keys keyp) parsed
        (if (and (null optional) (not keyp))
            `(let ,(mapcar #'list required arguments)
               ,@declarations
               (%with-inline ,name ,body))
            (let ((temp-bindings '())
                  (param-bindings '())
                  (args arguments))
              (dolist (var required)
                (let ((temp (gensym "ARG")))
                  (push (list temp (pop args)) temp-bindings)
                  (push (list var temp) param-bindings)))
              (dolist (spec optional)
                (destructuring-bind (var init) spec
                  (if args
                      (let ((temp (gensym "ARG")))
                        (push (list temp (pop args)) temp-bindings)
                        (push (list var temp) param-bindings))
                      (push (list var init) param-bindings))))
              (when keyp
                (let ((supplied '()))
                  (loop for (k v) on args by #'cddr
                        for temp = (gensym "ARG")
                        do (push (list temp v) temp-bindings)
                           (unless (assoc k supplied :test #'eq)
                             (push (cons k temp) supplied)))
                  (dolist (spec keys)
                    (destructuring-bind (kw var init) spec
                      (let ((hit (assoc kw supplied :test #'eq)))
                        (push (list var (if hit (cdr hit) init)) param-bindings))))))
              (let ((inner `(%with-inline ,name
                              (let* ,(nreverse param-bindings)
                                ,@declarations
                                ,body))))
                (if temp-bindings
                    (let ((temps (nreverse temp-bindings)))
                      `(let ,temps
                         (declare (ignorable ,@(mapcar #'first temps)))
                         ,inner))
                    inner))))))))

(defun symbol-macro-expansion (client environment name)
  "The expansion of NAME if it names a symbol macro in ENVIRONMENT, and
true; else NIL and NIL."
  (if (symbolp name)
      (let ((d (trucler:describe-variable client environment name)))
        (if (typep d 'trucler:symbol-macro-description)
            (values (trucler:expansion d) t)
            (values nil nil)))
      (values nil nil)))

;;; Compiler macros are owned by the compilation environment, including
;;; the wrapped host-library expanders used by cross compilation.
(defgeneric client-compiler-macro (client environment name)
  (:method (client environment name)
    (declare (ignore client environment name))
    nil))

(defgeneric client-type-expander (client environment name)
  (:method (client environment name)
    (declare (ignore client environment name))
    nil))

(defvar *compiler-macro-depth* 0)

(define-condition compiler-macro-expansion-warning (style-warning)
  ((form :initarg :form :reader compiler-macro-warning-form)
   (cause :initarg :cause :reader compiler-macro-warning-cause))
  (:report (lambda (condition stream)
             (format stream "Compiler macro expansion of ~S failed: ~A"
                     (compiler-macro-warning-form condition) (compiler-macro-warning-cause condition)))))

(defun compiler-macro-call-name (form)
  (when (consp form)
    (if (and (eq (first form) 'funcall) (consp (rest form))
             (consp (second form)) (eq (first (second form)) 'function)
             (consp (rest (second form))) (null (cddr (second form)))
             (or (symbolp (second (second form)))
                 (setf-function-name-p (second (second form)))))
        (second (second form))
        (and (symbolp (first form)) (first form)))))

(defun compiler-macro-expander (client environment name)
  (unless (or (member name *local-notinline* :test #'equal)
              (and (boundp '*inline-functions*) (eq (gethash name *inline-functions*) :notinline)))
    (let ((description (trucler:describe-function client environment name)))
      (when (or (null description)
                (and (typep description '(or trucler:global-function-description trucler:global-macro-description))
                     (not (eq (ignore-errors (trucler:inline description)) 'notinline))))
        (note-dependency :compiler-macro name)
        (client-compiler-macro client environment name)))))

(defun compiler-macro-expansion (client environment form)
  "The expansion of FORM, a call of a global function, by its compiler
macro. The second value distinguishes a NIL expansion from declining."
  (when (and *inline-enabled* (hir-policy-optimize-p *hir-policy*) (< *compiler-macro-depth* 64))
    (let* ((name (compiler-macro-call-name form))
           (expander (and name (compiler-macro-expander client environment name))))
      (when expander
        (handler-case
            (let ((expansion (funcall expander form environment)))
              (unless (eq expansion form) (values expansion t)))
          (error (condition)
            (warn 'compiler-macro-expansion-warning :form form :cause condition)
            (values nil nil)))))))

;;; Reading

(defparameter *target-features*
  '(:kiln :common-lisp :ansi-cl :64-bit :x86-64 :little-endian
    :ieee-floating-point :unix :linux)
  "The features of the target, for #+ and #- in target sources (not the
host's: an #+SBCL branch must not be read into kiln code).")

;;; Reading target sources: #. evaluates in the compile-time environment.
(defclass source-reader-client (#+kiln eclector.reader::kiln-client
                               eclector.concrete-syntax-tree::cst-client) ())

(defmethod eclector.reader:evaluate-expression ((client source-reader-client) expression)
  (compile-time-eval expression))

(defmethod eclector.concrete-syntax-tree::reconstruct-expression-parts
    ((client source-reader-client) expression children)
  (let* ((cons-table (reduce #'cst::cons-table children
                             :initial-value (make-hash-table :test #'eq)
                             :from-end t))
         (count (hash-table-count cons-table)))
    (flet ((reconstruct-part (part)
             (let ((table (cst::referenced-cons-table part cons-table)))
               (reduce (lambda (child table) (cst::add-atoms child table count))
                       children :initial-value table :from-end t)
               (cst:cst-from-expression part :source nil :expression->cst table))))
      (values (reconstruct-part (car expression))
              (reconstruct-part (cdr expression))))))

(defvar *source-reader-client* (make-instance 'source-reader-client))

(defvar *file-reader-package* nil)
(defvar *file-reader-external-format* :default)
(defvar *file-form-hook* nil)
(defvar *file-compilation-p* nil)

(defun map-file-csts (function path)
  "Reads the forms of PATH one at a time and calls FUNCTION on each CST
before reading the next, so that IN-PACKAGE takes effect for the rest of
the file. Reading starts in KILN-USER, with the target's features."
  (with-open-file (in path :external-format *file-reader-external-format*)
    (let ((*package* (or *file-reader-package* (find-package #-kiln '#:kiln-user #+kiln '#:common-lisp-user)))
          (*read-eval* (if *file-compilation-p* *read-eval* t))
          (eclector.base:*client* *source-reader-client*))
      (loop with eof = (list nil)
            for cst = (let ((*features* *target-features*))
                        (eclector.concrete-syntax-tree:read in nil eof))
            until (eq cst eof)
            do (when *file-form-hook* (funcall *file-form-hook* (cst:raw cst)))
               (funcall function cst)))))

;;; Top-level form processing (CLHS 3.2.3.1)

(defvar *defined-packages*)             ; host packages created by DEFPACKAGE forms
(defvar *toplevel-asts*)                ; TOPLEVEL-FORMs (lower.lisp), most recent first

;;; Where the top-level form being processed comes from, for the debug
;;; information of the functions compiled from it.
(defvar *source-file* nil)              ; the file's name (one string per file), or NIL
(defvar *toplevel-source* nil)          ; (START . END) of the outermost form, or NIL
(defvar *definition-name* nil)          ; DEFINITION-NAME of the innermost definition form
(defvar *eval-definition* nil)          ; the definition EVAL (native.lisp) is evaluating
(defvar *eval-form* nil)                ; the form EVAL was given, before expansion
(defvar *toplevel-raw* nil)             ; the outermost top-level form, as written

(defun cst-source-range (cst)
  "The source range (START . END) of CST if it has one."
  (let ((source (and (typep cst 'cst:cst) (cst:source cst))))
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

(defgeneric evaluate-at-compile-time (client input environment)
  (:documentation "Evaluates INPUT, a CST or a form, at compile time in the
Trucler ENVIRONMENT, for CLIENT. Cross and image clients use the HIR evaluator."))

(defun compile-time-eval (cst)
  (evaluate-at-compile-time *client* cst *environment*))

(defun compile-toplevel-form (cst compile-time-too)
  (when compile-time-too
    (compile-time-eval cst))
  (push (make-toplevel-form (let ((*inline-enabled* t)) (cst-to-hir cst *environment*))
                            *source-file* *toplevel-source* *definition-name*
                            *toplevel-raw*)
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
                   ((and (not (typep description 'trucler:local-function-description))
                         (cmd:macro-function-exists-p op))
                    (values (cmd:macroexpand-1 form *environment*) t))
                   (t (values nil nil))))))))

(defun compile-time-macroexpand-1 (form env)
  (let ((*environment* (or env *environment*)))
    (if (and (consp form) (symbolp (first form)))
        (multiple-value-bind (expansion macrop) (macroexpand-toplevel form)
          (if macrop (values expansion t) (values form nil)))
        (values form nil))))

(defun process-eval-when (cst compile-time-too)
  (let* ((parts (rest (hir-parts cst)))
         (situations (hir-raw (first parts)))
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
  (let ((raw (hir-raw cst)))
    (and (consp raw) (eq (first raw) 'declare))))

(defun check-symbol-macro-name (name environment)
  (unless (and (symbolp name) name (not (eq name t)) (not (keywordp name)))
    (hir-error "Invalid symbol macro name ~S" name))
  (let ((description (trucler:describe-variable *client* environment name)))
    (when (typep description '(or trucler:constant-variable-description
                                 trucler:global-special-variable-description))
      (hir-error "Symbol macro ~S names a constant or special variable" name))))

(defun process-toplevel-body (cst compile-time-too)
  "LOCALLY, MACROLET and SYMBOL-MACROLET at top level: their body forms are
top-level forms too (CLHS 3.2.3.1), processed in the environment with the
local macros added. A body that starts with declarations is compiled as a
whole instead (the declarations would otherwise be lost)."
  (let* ((form (hir-raw cst))
         (parts (hir-parts cst))
         (body (if (eq (first form) 'locally)
                   (rest parts)
                   (cddr parts))))
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
                         (let ((expander (evaluate-at-compile-time
                                          *client*
                                          `(function ,(ecclesia:parse-macro-using-canonicalization name lambda-list body))
                                          env)))
                           (setf env (trucler:add-local-macro *client* env name expander)))))))
                  (symbol-macrolet
                   (let ((env *environment*))
                     (dolist (binding (second form) env)
                       (unless (and (consp binding) (consp (cdr binding))
                                    (null (cddr binding)))
                         (hir-error "Invalid symbol macro binding ~S" binding))
                       (check-symbol-macro-name (first binding) *environment*)
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

(defun note-class-accessors (form)
  ;; The macro client's compile-time action receives no slot specifications.
  ;; Record the source-level names before DEFCLASS expands them away.
  (dolist (slot (fourth form))
    (when (consp slot)
      (loop for (option name) on (rest slot) by #'cddr
            do (case option
                 ((:reader :accessor) (setf (gethash name *defined-functions*) t)))
               (case option
                 (:writer (setf (gethash name *defined-functions*) t))
                 (:accessor (setf (gethash (list 'setf name) *defined-functions*) t)))))))

(defun process-toplevel (cst compile-time-too)
  (let* ((form (hir-raw cst))
         (*macro-source* (or (cst-source-range cst) *macro-source*))
         (*definition-name* (multiple-value-bind (name function-p) (definition-name form)
                              (if name (cons name function-p) *definition-name*))))
    (when (and (consp form) (eq (first form) 'defclass))
      (note-class-accessors form))
    (when (and (consp form) (eq (first form) 'defun) (consp (rest form)) (consp (cddr form)))
      (note-inline-definition form))
    (if (and (consp form) (symbolp (first form)))
        (case (first form)
          (progn
            (dolist (c (rest (hir-parts cst)))
              (process-toplevel c compile-time-too)))
          (eval-when
           (process-eval-when cst compile-time-too))
          ;; The host reader reads the rest of the file in the package.
          ;; Once the package system exists at run time, *PACKAGE* is
          ;; set at load time too, as LOAD would (code run at load time
          ;; uses it), and reset to CL-USER at the end
          ;; of the file (FRONT-END).
          (in-package
           (setf *package* (or (find-package (renamed-package-name (second form)))
                               (error "IN-PACKAGE: no package named ~S" (second form))))
           (when (run-time-packages-p *client*)
             (setf *file-sets-package* t)
             (let ((*macro-source* nil))
               (compile-toplevel-form
                `(setq *package* (,(find-package-function)
                                  ',(package-name *package*)))
                nil))))
          ;; Cross compilation creates the package in the host, so that the rest
          ;; of the sources can be read. Nothing is compiled: the run-time
          ;; package is built from the module's symbol table, which
          ;; mirrors the host package. A package that
          ;; exists already (a host system such as Ecclesia) is left
          ;; alone, but it is a package of the module too: its external
          ;; symbols are in the module whichever host compiles it (on
          ;; kiln, every package of kiln's sources exists).
          (defpackage
           (if *file-compilation-p*
               (multiple-value-bind (expansion expandedp) (macroexpand-toplevel form)
                 (unless expandedp (error "No DEFPACKAGE expander is available."))
                 (process-toplevel expansion compile-time-too))
               (let ((name (renamed-package-name (second form))))
                 (pushnew (or (find-package name)
                              (eval `(defpackage ,name ,@(cddr form))))
                          *defined-packages*))))
          ((locally macrolet symbol-macrolet)
           (process-toplevel-body cst compile-time-too))
          (t
           (multiple-value-bind (expansion macrop) (macroexpand-toplevel form)
             (if macrop
                 (process-toplevel expansion compile-time-too)
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
  (inline-functions (make-hash-table :test 'equal))
  (hir-source-files (make-hir-buffer)))

(defun make-session (&key (client-class #-kiln 'cross-client #+kiln 'image-client))
  "A session whose client is an instance of CLIENT-CLASS: CROSS-CLIENT, or
on kiln IMAGE-CLIENT (the default there)."
  (let* ((client (make-instance client-class))
         (session (%make-session :client client
                                 :environment (make-compile-environment client))))
    (initialize-session client session)))

(defmethod trucler:describe-variable
    ((client client) (environment trucler-reference:environment) name)
  (let* ((descriptions (trucler-reference::variable-description environment))
         (description (and descriptions
                           (find name descriptions :test #'eq :key #'trucler:name))))
    (trucler-reference::check-restriction
     environment
     (or description
         (trucler:describe-variable
          client (trucler-reference::global-environment environment) name)))))

(defmethod trucler:describe-function
    ((client client) (environment trucler-reference:environment) name)
  (let* ((descriptions (trucler-reference::function-description environment))
         (description (and descriptions
                           (find name descriptions :test #'equal :key #'trucler:name))))
    (trucler-reference::check-restriction
     environment
     (or description
         (trucler:describe-function
          client (trucler-reference::global-environment environment) name)))))

(defun forget-global-descriptions (environment)
  "Trucler's reference environment caches the descriptions of global
functions and variables it has looked up. The session's environment lives
across files, so the cache would hide later redefinitions (a macro
redefined by a later module, a function that becomes a macro); it is
cleared before each top-level form. At top level the environment holds
nothing else."
  (when (or (trucler-reference::function-description environment)
            (trucler-reference::variable-description environment))
    (reinitialize-instance environment :function-description '() :variable-description '())))

(defvar *trace-toplevel* nil
  "True: FRONT-END prints each file and the head of each top-level form
to *ERROR-OUTPUT*, for finding the form that an error comes from.")

(defun front-end (paths &optional (session (make-session)))
  "Reads and processes the top-level forms of the files PATHS (or
(:COMPILE-TIME-TOO path) elements), in order,
as one compilation unit, in SESSION. Returns the TOPLEVEL-FORMs (lower.lisp) of the
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
           (let ((*macro-source* nil))
             (compile-toplevel-form
              `(setq *package* (,(find-package-function) "COMMON-LISP-USER"))
              nil))))))))

(defun front-end-forms (forms &optional (session (make-session)))
  "As FRONT-END, for the top-level FORMS (for COMPILE)."
  (call-with-front-end
   session
   (lambda ()
     (let ((*package-renames* '())
           (*file-sets-package* nil))
       (dolist (form forms)
         (process-toplevel-cst form nil))))))

(defun process-toplevel-cst (cst compile-time-too)
  (forget-global-descriptions *environment*)
  (when *trace-toplevel*
    (let ((raw (hir-raw cst)))
      (format *error-output* "~&  ~S~@[ ~S~]~%"
              (if (consp raw) (first raw) raw)
              (and (consp raw) (consp (rest raw))
                   (atom (second raw)) (second raw)))))
  ;; As SBCL's COMPILE-FILE: gensyms are numbered from 0 in each
  ;; top-level form. COMPILE-MODULE names those in constants by their
  ;; order in the module (MODULE-SYMBOL-NAME).
  (let ((*gensym-counter* 0)
        (*toplevel-source* (cst-source-range cst))
        (*macro-source* (cst-source-range cst))
        (*definition-name* *eval-definition*)
        (*toplevel-raw* (or *eval-form* (hir-raw cst)))
        (*hir-file-id* (hir-source-file-number *source-file*))
        (*hir-top-cst* (and (typep cst 'cst:cst) cst))
        (*hir-form-sources* nil))
    (process-toplevel cst compile-time-too)))

(defun call-with-front-end (session thunk)
  "Calls THUNK, which processes top-level forms, with the front end's state
bound for SESSION. Returns the TOPLEVEL-FORMs of the forms to compile, in
order, and the host packages that DEFPACKAGE forms created."
  (let* ((*client* (session-client session))
         (#-kiln cmd:*client* #+kiln kiln.cmd:*client* *client*)
         (*environment* (session-environment session))
         (*toplevel-asts* '())
         (*defined-functions* (session-defined-functions session))
         (*referenced-functions* (make-hash-table :test 'equal))
         (*referenced-variables* (make-hash-table :test 'eq))
         (*defined-packages* '())
         (*structures* (session-structures session))
         (*inline-functions* (session-inline-functions session))
         (*toplevel-environment* *environment*)
         (*hir-source-files* (session-hir-source-files session))
         (*hir-current-source-file* :uninitialized) (*hir-file-id* 0))
    ;; Calls to functions defined later in the file are fine: report
    ;; undefined functions at the end (CLHS 3.2.2.3).
    (funcall thunk)
    (let ((undefined (loop for name being the hash-keys of *referenced-functions*
                           unless (or (gethash name *defined-functions*)
                                      (gethash name *primitives*)
                                      (eq name 'kiln.sys:%primop))
                             collect name)))
      (when undefined
        (warn 'undefined-function-warning :names undefined)))
    (values (nreverse *toplevel-asts*) (nreverse *defined-packages*))))
