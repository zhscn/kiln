;;;; Cross compilation (docs/11 §9): the compile-time environment is a
;;;; Clostrum environment, separate from the image that compiles, in which
;;;; Common-boot's HIR evaluator runs the code evaluated at compile time.
;;;; The functions of the compiling image ("the host") are imported into
;;;; it, so macro expanders can call them. SBCL compiles kiln this way, and
;;;; so does kiln (M5.4): there the host is kiln itself. Loaded after
;;;; front.lisp.

(in-package #:kiln.compiler)

(defclass cross-client (client cbe:client)
  ())

(defmethod cb:convert-with-ordinary-macro-p ((client cross-client) operator)
  #-kiln (cmd:macro-function-exists-p operator)
  ;; kiln: the compile-time environment has Common-macros' macros
  ;; (MAKE-COMPILE-ENVIRONMENT).
  #+kiln (declare (ignore operator))
  #+kiln nil)

(defun common-macro-p (name)
  "True if Common-macros defines the standard macro NAME."
  #-kiln (cmd:macro-function-exists-p name)
  #+kiln (and (assoc name kiln.kernel::*common-macros*) t))

(defvar *host-library-packages* '()
  "The packages of the libraries whose macros and functions are the host's
at compile time (USE-HOST-MACROS).")

(defmethod #-kiln cmd:get-setf-expansion #+kiln kiln.cmd:get-setf-expansion
    ((client cross-client) place &optional environment)
  (let ((environment (or environment *environment*)))
    (cond ((symbolp place)
           (multiple-value-bind (expansion macrop)
               (symbol-macro-expansion client environment place)
             (if macrop
                 (#-kiln cmd:get-setf-expansion #+kiln kiln.cmd:get-setf-expansion
                  client expansion environment)
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
                       (#-kiln cmd:get-setf-expansion #+kiln kiln.cmd:get-setf-expansion
                        client expansion environment)
                       (call-next-method))))))
          (t (call-next-method)))))

(defun proclaim-in (client genv declaration)
  (when (and (consp declaration) (eq (first declaration) 'special))
    (dolist (name (rest declaration))
      (clo:make-variable client genv name)))
  (when (and (consp declaration) (member (first declaration) '(inline notinline)))
    (note-inline-proclamation (first declaration) (rest declaration)))
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
        (unless (or (gethash name *host-macros*)
                    (and *package-renames*
                         (or (clo:macro-function client genv name)
                             (and (symbolp name)
                                  (eq (symbol-package name) (find-package '#:common-lisp))
                                  (common-macro-p name)))))
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
        (#-kiln cmd:get-setf-expansion #+kiln kiln.cmd:get-setf-expansion client place env)))
    (def 'kiln.sys::%deftype
      (lambda (name expander)
        (setf (clo:type-expander client genv name) expander)
        name))
    ;; DEFCONSTANT's compile-time side (lisp/target/kernel.lisp). The
    ;; constants of the libraries the host has loaded are the host's
    ;; (USE-HOST-MACROS): Clostrum-basic's +UNBOUND+ is the marker of an
    ;; unbound cell of the compile-time environment itself.
    (def 'kiln.sys::%define-constant
      (lambda (name value)
        (unless (host-constant-p name)
          (clo:make-constant client genv name value))
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
    ;; EVAL in a macro expander (Maclina's DEFOPS) sees the compile-time
    ;; definitions.
    (def 'eval
      (lambda (form)
        (cb:eval-cst client (cst:cst-from-expression form) *toplevel-environment*)))
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

;;; On kiln, Common-macros is the eval module's KILN.CMD. A cross
;;; compilation must produce what the host's does, where it is
;;; COMMON-MACRO-DEFINITIONS: the symbols of KILN.CMD that an expansion
;;; introduces (CHECK-TYPE-ERROR, WITH-STORE-VALUE-RESTART) are renamed to
;;; that package's. Those of the form expanded are kept: the eval module's
;;; sources name KILN.CMD's symbols themselves.
#+kiln
(defun host-cmd-symbol (symbol)
  (intern (symbol-name symbol) '#:common-macro-definitions))

#+kiln
(defun cross-common-macro (expander)
  (let ((cmd (find-package '#:kiln.cmd)))
    (lambda (form env)
      (let ((own (make-hash-table :test 'eq))
            (done (make-hash-table :test 'eq)))
        (labels ((note (x)
                   (cond ((gethash x own))
                         ((consp x) (setf (gethash x own) t) (note (car x)) (note (cdr x)))
                         ((and (symbolp x) (eq (symbol-package x) cmd)) (setf (gethash x own) t))))
                 ;; The conses of FORM are kept, for their source
                 ;; positions; others are copied only if they change.
                 (walk (x)
                   (cond ((gethash x own) x)
                         ((gethash x done))
                         ((consp x)
                          (setf (gethash x done) x)
                          (let ((car (walk (car x)))
                                (cdr (walk (cdr x))))
                            (setf (gethash x done)
                                  (if (and (eq car (car x)) (eq cdr (cdr x)))
                                      x
                                      (cons car cdr)))))
                         ((and (symbolp x) (eq (symbol-package x) cmd) (not (gethash x own)))
                          (host-cmd-symbol x))
                         (t x))))
          (note form)
          (let ((expansion (funcall expander form env)))
            (if (eq expansion form) form (walk expansion))))))))

(defmethod make-compile-environment ((client cross-client))
  (let* ((env (cb:create-environment))
         (genv (trucler:global-environment client env)))
    ;; Common-macros' macros: CREATE-ENVIRONMENT takes them from the host's
    ;; COMMON-MACRO-DEFINITIONS package; on kiln they are the ones the eval
    ;; module saved (lisp/target/eval/macros.lisp).
    #-kiln (do-external-symbols (s '#:common-lisp)
             (let ((expander (and (not (special-operator-p s)) (cmd:macro-function s))))
               (when expander
                 (setf (clo:macro-function client genv s) expander))))
    #+kiln (loop for (name . expander) in kiln.kernel::*common-macros*
                 do (setf (clo:macro-function client genv name)
                          (cross-common-macro expander)))
    ;; Their internal macros (CHECK-TYPE's WITH-STORE-VALUE-RESTART), with
    ;; the host's names.
    #+kiln (do-symbols (s '#:kiln.cmd)
             (when (and (eq (symbol-package s) (find-package '#:kiln.cmd)) (macro-function s))
               (setf (clo:macro-function client genv (host-cmd-symbol s))
                     (cross-common-macro (macro-function s)))))
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
    (host-macro client genv 'loop (macro-function #-kiln 'khazern-extrinsic:loop #+kiln 'loop))
    (host-macro client genv 'loop-finish
                (macro-function #-kiln 'khazern-extrinsic:loop-finish #+kiln 'loop-finish))
    ;; DEFPACKAGE not at top level (top-level ones are processed in the
    ;; host, PROCESS-TOPLEVEL) runs at run time (lisp/target/clos/package-system.lisp).
    (host-macro client genv 'defpackage
                (lambda (form env)
                  (declare (ignore env))
                  `(eval-when (:compile-toplevel :load-toplevel :execute)
                     (kiln.kernel::%defpackage ',(second form) ',(cddr form)))))
    ;; Code evaluated at compile time sees the target's features.
    (clo:make-variable client genv '*features* (copy-list *target-features*))
    ;; DEFSTRUCT is Anatomicl's, expanded in the host (structures.lisp).
    (host-macro client genv 'defstruct #'expand-defstruct)

    (setf (clo:macro-function client genv 'kiln.sys::closer-mop-aliases)
          #'expand-closer-mop-aliases)
    (setf (clo:macro-function client genv 'load-time-only) #'expand-load-time-only)
    env))

;;; Libraries that the host has loaded too (the front end's dependencies,
;;; docs/11 §3) have their macros expanded by the host's definitions at
;;; compile time, as LOOP is. Their expanders call functions and use data
;;; (parser.packrat's grammars, let-plus's generic functions) that exist at
;;; compile time only in the host; some of their macros are defined by
;;; forms that are not at top level (anaphora's ANAPHORIC). An expansion
;;; must not contain host objects, which could not be compiled.

(defun host-object-p (object)
  (not (typep object '(or symbol number character string))))

(defun check-host-expansion (name expansion)
  (let ((seen (make-hash-table :test 'eq)))
    (labels ((walk (x)
               (cond ((gethash x seen))
                     ((consp x)
                      (setf (gethash x seen) t)
                      (walk (car x))
                      (walk (cdr x)))
                     ((and (symbolp x) (symbol-package x)
                           (let ((package (package-name (symbol-package x))))
                             (and (> (length package) 3) (string= "SB-" package :end2 3))))
                      (error "The host expansion of ~S contains the host symbol ~S." name x))
                     ((and (vectorp x) (not (stringp x)))
                      (setf (gethash x seen) t)
                      (map nil #'walk x))
                     ((host-object-p x)
                      (error "The host expansion of ~S contains ~S." name x)))))
      (walk expansion))))

;;; A macro-defining macro's expansion contains the host's backquote
;;; (SB-INT:QUASIQUOTE forms with SB-IMPL::COMMA objects): it is rewritten
;;; with Eclector's QUASIQUOTE, UNQUOTE and UNQUOTE-SPLICING, which are
;;; macros at compile time (MAKE-COMPILE-ENVIRONMENT) and run time.
(defun translate-host-backquote (form)
  #-sbcl form
  #+sbcl
  (let ((done (make-hash-table :test 'eq)))
    (labels ((walk (x)
               (cond ((typep x 'sb-impl::comma)
                      (list (if (zerop (sb-impl::comma-kind x))
                                'eclector.reader:unquote
                                'eclector.reader:unquote-splicing)
                            (walk (sb-impl::comma-expr x))))
                     ((gethash x done))
                     ((consp x)
                      (setf (gethash x done)
                            (cons (if (eq (car x) 'sb-int:quasiquote)
                                      'eclector.reader:quasiquote
                                      (walk (car x)))
                                  (walk (cdr x)))))
                     ((and (simple-vector-p x) (some (lambda (e) (or (consp e) (typep e 'sb-impl::comma))) x))
                      (setf (gethash x done) (map 'vector #'walk x)))
                     (t x))))
      (walk form))))

(defun host-constant-p (name)
  (and (symbolp name)
       (member (symbol-package name) *host-library-packages*)
       (constantp name)))

(defmethod trucler:describe-variable :around ((client cross-client) environment name)
  (or (call-next-method)
      (and (host-constant-p name)
           (make-instance 'trucler:constant-variable-description
             :name name :value (symbol-value name)))))

;;; (LOAD-TIME-ONLY form...) in a host expansion, at top level: the forms
;;; are compiled but not evaluated at compile time, even in an EVAL-WHEN
;;; with :COMPILE-TOPLEVEL (they would change the host's state:
;;; parser.packrat's DEFRULE there would replace the host's rule by one
;;; that the compile-time evaluator runs). Not at top level, the forms are
;;; dropped.
(defun expand-load-time-only (form env)
  (declare (ignore env))
  `(eval-when (:load-toplevel) ,@(rest form)))

(defvar *host-compiler-macros* (make-hash-table :test 'eq)
  "Function names -> the host's compiler macros, wrapped (USE-HOST-MACROS).")

(defmethod client-compiler-macro ((client cross-client) name)
  (gethash name *host-compiler-macros*))

(defun use-host-macros (session package-names)
  "The macros whose home is one of the packages PACKAGE-NAMES are expanded
by the host's expanders at compile time in SESSION, and code evaluated at
compile time calls the host's functions of those packages (the expansions
evaluate some at compile time: parser.packrat's DEFGRAMMAR)."
  (let* ((client (session-client session))
         (genv (trucler:global-environment client (session-environment session))))
    (dolist (package-name package-names)
      (let ((package (or (find-package package-name)
                         (error "No host package ~A." package-name))))
        (pushnew package *host-library-packages*)
        (do-symbols (s package)
          (when (eq (symbol-package s) package)
            (when (and (fboundp s) (not (macro-function s)) (not (special-operator-p s)))
              (setf (clo:fdefinition client genv s) (fdefinition s)))
            (when (fboundp `(setf ,s))
              (setf (clo:fdefinition client genv `(setf ,s)) (fdefinition `(setf ,s)))))
          (let ((expander (and (eq (symbol-package s) package) (compiler-macro-function s))))
            (when expander
              (let ((name s))
                ;; A compiler macro may decline: an expansion that is not
                ;; target code (host objects) declines too.
                (setf (gethash s *host-compiler-macros*)
                      (lambda (form env)
                        (let ((raw (funcall expander form env)))
                          (if (eq raw form)
                              form
                              (let ((expansion (translate-host-backquote raw)))
                                (handler-case (progn (check-host-expansion name expansion)
                                                     expansion)
                                  (error () form))))))))))
          (let ((expander (and (eq (symbol-package s) package) (macro-function s))))
            (when expander
              (let ((name s))
                (host-macro client genv s
                            (lambda (form env)
                              (let ((expansion (translate-host-backquote
                                                (funcall expander form env))))
                                (check-host-expansion name expansion)
                                expansion)))))))))))

;;; Compiling the compiler module (docs/11 §8), on the host or on kiln.

(defparameter *compiler-host-macro-packages*
  ;; Expanded by the host at compile time (USE-HOST-MACROS).
  '("ANAPHORA" "LET-PLUS" "MORE-CONDITIONS" "UTILITIES.PRINT-ITEMS"
    "ARCHITECTURE.BUILDER-PROTOCOL" "PARSER.PACKRAT.CACHE" "PARSER.PACKRAT.BASE"
    "PARSER.PACKRAT.EXPRESSION" "PARSER.PACKRAT.ENVIRONMENT" "PARSER.PACKRAT.COMPILER"
    "PARSER.PACKRAT.GRAMMAR" "PARSER.PACKRAT.GRAMMAR.BASE"
    "PARSER.PACKRAT.GRAMMAR.SEQUENCE" "PARSER.PACKRAT.GRAMMAR.SEXP"
    "PARSER.PACKRAT.BOOTSTRAP" "PARSER.PACKRAT" "S-EXPRESSION-SYNTAX.EXPRESSION-GRAMMAR"
    "S-EXPRESSION-SYNTAX" "S-EXPRESSION-SYNTAX.CONCRETE-SYNTAX-TREE" "ICONOCLAST"
    "ICONOCLAST-BUILDER" "TRUCLER-REFERENCE" "CLOSTRUM-SYS" "CLOSTRUM"
    "CLOSTRUM-IMPLEMENTATION" "CLOSTRUM-BASIC" "CLOSTRUM-TRUCLER" "ICONOCLAST-AST-WALKER"
    "ICONOCLAST-AST-TRANSFORMATIONS" "COMMON-MACROS" "COMMON-BOOT" "COMMON-BOOT-HIR"
    "COMMON-BOOT-AST-TO-HIR" "COMMON-BOOT-HIR-EVALUATOR"))

(defun load-time-only-definitions (expansion)
  "EXPANSION of a parser.packrat or s-expression-syntax definition macro
with its compile-time definitions removed and its load-time ones wrapped
in LOAD-TIME-ONLY."
  (labels ((walk (form)
             (cond ((atom form) form)
                   ((and (eq (first form) 'eval-when)
                         (equal (second form) '(:compile-toplevel)))
                    nil)
                   ((member (first form) '(parser.packrat.grammar:ensure-grammar
                                           parser.packrat.grammar:ensure-rule
                                           s-expression-syntax::ensure-syntax))
                    `(load-time-only ,form))
                   ((eq (first form) 'progn)
                    (cons 'progn (mapcar #'walk (rest form))))
                   (t form))))
    (walk expansion)))

(defun prepare-compiler-session (session)
  "Makes SESSION, which has compiled the kernel, CLOS, the front end and
eval, ready to compile the compiler module: the host libraries' macros and
the compile-time definitions that the module needs."
  (use-host-macros session *compiler-host-macro-packages*)
  (let* ((client (session-client session))
         (genv (trucler:global-environment client (session-environment session))))
    ;; The host's DEFRULE compiles a rule in the host's current grammar.
    (host-macro
     client genv 'parser.packrat:in-grammar
     (lambda (form env)
       (declare (ignore env))
       (setf parser.packrat::*grammar* (parser.packrat.grammar:find-grammar (second form)))
       `(eval-when (:load-toplevel :execute)
          (setf parser.packrat::*grammar*
                (parser.packrat.grammar:find-grammar ',(second form))))))
    ;; The host has the grammars, rules and syntax descriptions already;
    ;; defining them at compile time would replace the host's.
    (dolist (name '(parser.packrat:defgrammar parser.packrat:defrule
                    s-expression-syntax::define-syntax))
      (let ((expander (clo:macro-function client genv name)))
        (host-macro
         client genv name
         (lambda (form env)
           (load-time-only-definitions (funcall expander form env))))))
    ;; The inline functions of the modules compiled so far
    ;; (lisp/target/compiler/session.lisp).
    (host-macro
     client genv 'host-inline-functions
     (lambda (form env)
       (declare (ignore form env))
       (let ((entries '()))
         (maphash (lambda (name entry) (push (cons name entry) entries))
                  (session-inline-functions session))
         (check-host-expansion 'host-inline-functions entries)
         `',entries)))))
