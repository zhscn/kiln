(in-package #:kiln)

(defparameter *kernel-files*
  (mapcar (lambda (name)
            (asdf:system-relative-pathname "kiln" (format nil "lisp/target/~A.lisp" name)))
          '("assumptions" "kernel" "early" "types" "sequences"))
  "Target kernel sources, compiled into the kernel module.")

(defun clostrophilia-file (system-directory name)
  (asdf:system-relative-pathname
   "kiln" (format nil "vendor/Clostrophilia/Code/~A/~A.lisp" system-directory name)))

(defun kiln-clos-file (name)
  (asdf:system-relative-pathname "kiln" (format nil "lisp/target/clos/~A.lisp" name)))

(defun predicament-file (name)
  (asdf:system-relative-pathname
   "kiln" (format nil "vendor/Predicament/Code/~A.lisp" name)))

(defparameter *predicament-files*
  ;; As predicament-common.asd. RESTART-BIND's and RESTART-CASE's
  ;; expanders call functions of their files.
  (mapcar (lambda (name)
            (if (member name '("restart-bind-defmacro" "restart-case-defmacro")
                        :test #'string=)
                (list :compile-time-too (predicament-file name))
                (predicament-file name)))
          '("break-on-signals-defparameter" "debugger-hook-defparameter"
            "default-debugger-defvar" "condition-maker-defvar"
            "restart-clusters-defparameter" "condition-restarts-defparameter"
            "restart-defclass" "restart-bind-defmacro" "coerce-to-condition"
            "restart-case-defmacro" "find-restart-defun" "compute-restarts"
            "signal-defgeneric" "error-defgeneric" "warn-defgeneric"
            "make-condition-defun" "invoke-debugger-defun"
            "handler-clusters-defparameter" "handler-bind-defmacro"
            "ignore-errors-defmacro" "with-simple-restart-defmacro"
            "with-condition-restarts" "warning-define-condition"
            "serious-condition-define-condition" "style-warning-define-condition"
            "error-define-condition" "cell-error-define-condition"
            "undefined-function-define-condition" "unbound-variable-define-condition"
            "unbound-slot-define-condition" "arithmetic-error-define-condition"
            "division-by-zero-define-condition" "floating-point-inexact-define-condition"
            "floating-point-invalid-operation-define-condition"
            "floating-point-overflow-define-condition"
            "floating-point-underflow-define-condition" "file-error-define-condition"
            "package-error-define-condition" "parse-error-define-condition"
            "print-not-readable-define-condition" "program-error-define-condition"
            "simple-condition-define-condition"
            "simple-error-define-condition" "type-error-define-condition"
            "simple-type-error-define-condition" "simple-warning-define-condition"
            "storage-condition-define-condition" "stream-error-define-condition"
            ;; kiln: after its superclass STREAM-ERROR (vendor/README.md).
            "reader-error-define-condition"
            "end-of-file-define-condition" "control-error-define-condition"
            "invoke-restart-defun" "invoke-restart-interactively-defun"
            "signal-defmethods" "error-defmethods" "cerror-defun"
            "invalid-method-error" "method-combination-error" "break-defun"
            "warn-defmethods" "abort-defun" "muffle-warning-defun" "continue-defun"
            "store-value-defun" "use-value-defun" "assert")))

(defparameter *parcl-files*
  ;; parcl-low, parcl-low-class, parcl-packages-intrinsic, parcl-common.
  (mapcar (lambda (name)
            (asdf:system-relative-pathname
             "kiln" (format nil "vendor/Parcl/Code/~A.lisp" name)))
          '("Low/packages" "Low/accessors" "Low/configuration" "Low/generic-functions"
            "Low/package-class" "Low/find-symbol" "Low/import" "Low/shadowing-import"
            "Low/use-packages" "Low/unuse-package" "Low/export" "Low/unexport"
            "Low/unintern" "Low/add-local-nickname" "Low/remove-local-nickname"
            "Low/condition-types"
            "Low/Class/packages" "Low/Class/client" "Low/Class/package-defclass"
            "Low/Class/methods" "Low/Class/map-symbols" "Low/Class/map-external-symbols"
            "packages-intrinsic"
            "variables" "utilities" "package-name" "package-nicknames"
            "package-shadowing-symbols" "package-use-list" "package-used-by-list"
            "intern" "find-symbol" "import" "shadowing-import" "use-package"
            "unuse-package" "export" "unexport" "shadow" "add-package-local-nickname"
            "remove-package-local-nickname" "make-package" "condition-types"))
  "Parcl, intrinsic: it defines the CL package functions.")

(defparameter *ctype-files*
  ;; As ctype.asd, with kiln's client instead of host.lisp and
  ;; runtime.lisp, and kiln's interface instead of interface.lisp.
  (mapcar (lambda (name)
            (if (string= name "ctype-client")
                (kiln-clos-file name)
                (asdf:system-relative-pathname
                 "kiln" (format nil "vendor/ctype/~A.lisp" name))))
          '("packages" "trivalent" "method-combination" "client" "ctype-client"
            "classes" "create" "generic-functions" "cclass" "negation"
            "conjunction" "disjunction" "ccons" "range" "fpzero" "ccomplex"
            "cmember" "carray" "csequence" "charset" "cvalues" "cfunction"
            "csatisfies" "pairwise" "parse")))

(defparameter *regalia-files*
  ;; The class hierarchy and a few common functions; kiln's arrays.lisp
  ;; does the rest.
  (mapcar (lambda (name)
            (asdf:system-relative-pathname
             "kiln" (format nil "vendor/Regalia/Code/~A.lisp" name)))
          (append '("Base-intrinsic/packages")
                  (mapcar (lambda (name) (format nil "Class-hierarchy/~A" name))
                          '("array" "array-t" "array-unsigned-byte-64"
                            "array-signed-byte-64" "array-unsigned-byte-32"
                            "array-signed-byte-32" "array-unsigned-byte-16"
                            "array-signed-byte-16" "array-unsigned-byte-8"
                            "array-signed-byte-8" "array-double-float"
                            "array-single-float" "array-complex-double-float"
                            "array-complex-single-float" "array-character" "vector"
                            "simple-vector" "vector-unsigned-byte-64"
                            "vector-signed-byte-64" "vector-unsigned-byte-32"
                            "vector-signed-byte-32" "vector-unsigned-byte-16"
                            "vector-signed-byte-16" "vector-unsigned-byte-8"
                            "vector-single-float" "vector-double-float"
                            "vector-complex-single-float" "vector-complex-double-float"
                            "array-bit" "bit-vector" "string"))
                  '("Common/variables" "Common/class-name-from-element-type"
                    "Common/check-dimensions" "Common/condition-types"))))

(defparameter *cyclosis-files*
  ;; As cyclosis.asd; kiln's streams.lisp replaces the intrinsic interface.
  (mapcar (lambda (name)
            (asdf:system-relative-pathname
             "kiln" (format nil "vendor/Cyclosis/code/~A.lisp" name)))
          '("packages" "interface" "conditions" "default-methods" "stream"
            "broadcast-stream" "concatenated-stream" "string-stream"
            "synonym-stream" "two-way-stream" "echo-stream" "posix-file-stream"
            "transcode/common" "transcode/character" "transcode/ascii"
            "transcode/iso-8859" "transcode/dos" "transcode/mac" "transcode/windows"
            "transcode/utf-8" "transcode/utf-32" "transcode/unsigned-byte")))

(defparameter *incless-files*
  ;; As incless.asd; kiln's printer.lisp replaces the intrinsic interface.
  (mapcar (lambda (name)
            (asdf:system-relative-pathname
             "kiln" (format nil "vendor/Incless/code/~A.lisp" name)))
          '("packages" "interface" "write-object" "integer" "rational" "float"
            "complex" "character" "string" "cons" "bit-vector" "array" "vector"
            "random-state" "pathname" "standard-object" "structure" "package"
            "symbol")))

(defparameter *inravina-files*
  ;; As inravina.asd; kiln's pprint.lisp replaces the intrinsic interface.
  ;; The logical block expander is called by macros at compile time.
  (mapcar (lambda (name)
            (let ((path (asdf:system-relative-pathname
                         "kiln" (format nil "vendor/Inravina/code/~A.lisp" name))))
              (if (member name '("logical-block") :test #'string=)
                  (list :compile-time-too path)
                  path)))
          '("packages" "types" "interface" "logical-block" "list-printers"
            "form-printers" "object-printers" "dispatch" "pretty-stream"
            "implementation")))

(defparameter *invistra-files*
  ;; As invistra.asd; kiln's format.lisp replaces the intrinsic interface.
  (mapcar (lambda (name)
            (asdf:system-relative-pathname
             "kiln" (format nil "vendor/Invistra/code/~A.lisp" name)))
          '("packages" "utilities" "conditions" "generic-functions" "directive"
            "parse-control-string" "format" "expansion" "basic-output"
            "radix-control" "floating-point-printers" "printer-operations"
            "pretty-printer-operations" "layout-control" "control-flow-operations"
            "miscellaneous-operations" "miscellaneous-pseudo-operations"
            "condition-reporters-en" "interface")))

(defparameter *khazern-files*
  ;; As khazern.asd; kiln's loop.lisp replaces the intrinsic interface.
  (mapcar (lambda (name)
            (asdf:system-relative-pathname "khazern" (format nil "code/~A.lisp" name)))
          '("packages" "interface" "utilities" "types" "conditions"
            "conditions-english" "binding" "parser" "clause" "expansion"
            "variable-init-and-stepping-clauses" "value-accumulation-clauses"
            "termination-test-clauses" "unconditional-execution-clauses"
            "conditional-execution-clauses" "miscellaneous-clauses")))

(defparameter *alexandria-files*
  ;; As alexandria.asd (alexandria-1). Also evaluated at compile time:
  ;; Eclector's sources use its macros. (The host's expanders cannot be
  ;; used: ONCE-ONLY's expansions contain the host's backquote.)
  (mapcar (lambda (name)
            (let ((path (asdf:system-relative-pathname
                         "alexandria" (format nil "alexandria-1/~A.lisp" name))))
              ;; Not the condition definitions (CLOS does not exist at
              ;; compile time), nor what the macros do not need.
              (if (member name '("conditions" "features" "io" "numbers") :test #'string=)
                  path
                  (list :compile-time-too path))))
          '("package" "definitions" "binding" "strings" "conditions" "symbols" "macros"
            "hash-tables" "control-flow" "functions" "lists" "types" "arrays" "sequences"
            "numbers" "features" "io")))

(defparameter *eclector-files*
  ;; As eclector.asd, without parse results; kiln's reader.lisp is the
  ;; interface.
  (mapcar (lambda (name)
            (asdf:system-relative-pathname "eclector" (format nil "code/~A.lisp" name)))
          '("base/package" "base/utilities" "base/variables" "base/generic-functions"
            "base/conditions" "base/read-char" "base/messages-english"
            "readtable/package" "readtable/variables" "readtable/conditions"
            "readtable/generic-functions" "readtable/messages-english"
            "readtable/simple/package" "readtable/simple/readtable"
            "readtable/simple/methods" "readtable/simple/messages-english"
            "reader/package" "reader/more-variables" "reader/generic-functions"
            "reader/additional-conditions" "reader/utilities" "reader/labeled-objects"
            "reader/tokens" "reader/read-common" "reader/read" "reader/macro-functions"
            "reader/init" "reader/quasiquote-macro" "reader/deprecation"
            "reader/messages-english")))

(defun clostrophilia-files (groups)
  "GROUPS: lists (DIRECTORY FILE...); a FILE is a name or
(:COMPILE-TIME-TOO name)."
  (loop for (directory . files) in groups
        append (loop for file in files
                     collect (if (consp file)
                                 (list :compile-time-too
                                       (clostrophilia-file directory (second file)))
                                 (clostrophilia-file directory file)))))

(defparameter *clos-files*
  (append
   (list (clostrophilia-file "Package" "packages")
         (kiln-clos-file "early"))
   (mapcar (lambda (name) (clostrophilia-file "Class-hierarchy" name))
           '("t" "function" "standard-object" "metaobject" "method" "standard-method"
             "standard-accessor-method" "standard-reader-method" "standard-writer-method"
             "slot-definition" "standard-slot-definition" "direct-slot-definition"
             "effective-slot-definition" "standard-direct-slot-definition"
             "standard-effective-slot-definition" "method-combination"
             "standard-method-combination" "specializer" "eql-specializer" "class"
             "forward-referenced-class" "real-class" "regular-class" "standard-class"
             "funcallable-standard-class" "built-in-class" "funcallable-standard-object"
             "simple-function" "generic-function" "standard-generic-function"))
   (list (kiln-clos-file "built-in-classes")
         (kiln-clos-file "braid")
         (kiln-clos-file "ecclesia")
         (kiln-clos-file "support"))
   (clostrophilia-files
    '(("Instance-structure" "slot-value-etc" "slot-value-etc-using-location")
      ("Method-combination" "condition-types"
       "accessor-defgenerics" "method-combination-template-defclass"
       "ensure-method-combination"
       ;; The functions DEFINE-METHOD-COMBINATION's expander calls.
       (:compile-time-too "method-group-specifier") (:compile-time-too "method-discriminator")
       (:compile-time-too "long-form-expansion") (:compile-time-too "short-form-expansion")
       "find-method-combination-defun" "define-method-combination-defmacro"
       "standard-method-combination" "built-in-method-combinations")
      ("Instance-structure" "slot-missing" "slot-unbound" "slot-boundp-using-class"
       "slot-value-using-class" "slot-makunbound-using-class" "find-slot"
       "slot-value-etc-using-only-class" "condition-types")
      ("Standard-object-initialization" "shared-initialize" "initialize-instance"
       "reinitialize-instance" "shared-initialize-aux")
      ("Class-finalization" "generic-functions" "compute-class-precedence-list"
       "compute-default-initargs" "effective-slot-definition-class"
       "compute-effective-slots" "finalize-inheritance")
      ("Generic-function-invocation" "classp" "sub-specializer-p" "specializer-profile"
       "compute-applicable-methods-using-classes" "compute-applicable-methods"
       "compute-effective-method" "discriminating-automaton" "discriminating-tagbody"
       "maybe-replace-method" "no-applicable-method" "standard-accessor-method-p"
       "compute-discriminating-function" "add-remove-direct-method"
       "invalidate-discriminating-function" "add-remove-method" "condition-types")
      ("Dependent-maintenance" "generic-functions" "methods")
      ("Generic-function-initialization" "check-declarations" "check-documentation"
       "method-combination-p" "initialize-instance-methods"
       "reinitialize-instance-methods" "shared-initialize-methods" "condition-types")
      ("Class-initialization" "remove-direct-subclass-defgeneric"
       "remove-direct-subclass-defmethod" "add-direct-subclass-defgeneric"
       "add-direct-subclass-defmethod" "default-superclasses"
       "direct-slot-definition-class" "reader-method-class" "writer-method-class"
       "validate-superclass-defgeneric" "validate-superclass-defmethods"
       "check-direct-default-initargs-defun" "check-superclass-list-defun"
       "add-accessor-method" "special-variables" "initialize-instance-defmethods"
       "reinitialize-instance-defmethods" "shared-initialize-methods"
       "allocate-instance" "allocate-instance-using-class" "condition-types")
      ("Method-initialization" "condition-types" "direct-slot-definition-p"
       "initialize-instance-methods" "reinitialize-instance-methods")
      ("Slot-definition-initialization" "condition-types" "initialize-instance-methods"
       "reinitialize-instance-methods")))
   (list (kiln-clos-file "switchover")
         (kiln-clos-file "predicament-package")
         (kiln-clos-file "conditions"))
   *predicament-files*
   (list (kiln-clos-file "early-conditions")
         (kiln-clos-file "runtime-errors"))
   (mapcar (lambda (name)
             (asdf:system-relative-pathname
              "kiln" (format nil "vendor/Salmagundi/code/~A.lisp" name)))
           '("packages" "utility" "generic-functions" "hash-table" "hash"
             "buckets/packages" "buckets/bucket-hash-table"))
   (list (kiln-clos-file "hash-tables"))
   *parcl-files*
   (list (kiln-clos-file "package-system"))
   *ctype-files*
   (list (kiln-clos-file "ctype-interface"))
   *regalia-files*
   (list (kiln-clos-file "arrays")
         (kiln-clos-file "structures")
         (kiln-clos-file "random")
         (kiln-clos-file "change-class")
         (kiln-clos-file "redefinition")
         (kiln-clos-file "constructors")
         (kiln-clos-file "load-forms")
         (kiln-clos-file "specialization")
         (kiln-clos-file "trivial-package-locks")
         ;; Trinsic, for the interfaces of Cyclosis and the printer modules.
         (asdf:system-relative-pathname "trinsic" "code/interface.lisp"))
   *cyclosis-files*
   (list (kiln-clos-file "streams")
         (kiln-clos-file "printer-support")
         (kiln-clos-file "quaviver"))
   *incless-files*
   (list (kiln-clos-file "printer")
         (kiln-clos-file "ngray"))
   *inravina-files*
   (list (kiln-clos-file "pprint"))
   (mapcar (lambda (name)
             (asdf:system-relative-pathname "acclimation" (format nil "~A.lisp" name)))
           '("packages" "locale" "language" "language-english" "condition" "init"))
   *invistra-files*
   (list (kiln-clos-file "format")
         (kiln-clos-file "pathnames")
         (kiln-clos-file "files")
         (kiln-clos-file "time")
         (kiln-clos-file "environment")
         (kiln-clos-file "trace")
         (kiln-clos-file "image")
         (kiln-clos-file "debug")
         (kiln-clos-file "profile")
         (kiln-clos-file "documentation")
         (kiln-clos-file "describe")
         (kiln-clos-file "closer-mop")
         (kiln-clos-file "trivial-with-current-source-form"))
   *khazern-files*
   (list (kiln-clos-file "loop"))
   *alexandria-files*
   *eclector-files*
   (list (kiln-clos-file "reader") (kiln-clos-file "finish")))
  "Sources of the CLOS module, in load order.")

(defun write-module (module output)
  (with-open-file (out output :direction :output :if-exists :supersede)
    (kiln.kir:print-module module out))
  output)

(defun compile-files (files session module-name &key extra-symbols)
  (multiple-value-bind (asts defined-packages) (kiln.compiler:front-end files session)
    (kiln.compiler:compile-module asts module-name
                                  :session session
                                  :defined-packages defined-packages
                                  :extra-symbols extra-symbols)))

(defun compile-kernel (output &key (session (kiln.compiler:make-session)))
  "Compiles the kernel to the KIR module OUTPUT. Programs compiled later
in SESSION see its macros and definitions."
  (write-module (compile-files *kernel-files* session "kernel"
                              ;; Every standard symbol exists at run time.
                              :extra-symbols (let ((symbols '()))
                                               (do-external-symbols (s '#:common-lisp symbols)
                                                 (push s symbols))))
                output))

(defun compile-file-to-kir (input output &key (session (kiln.compiler:make-session)))
  "Compiles the source file INPUT to the KIR module OUTPUT. Run it with the
kernel module first: kiln-cg jit kernel.kir OUTPUT."
  (write-module (compile-files (list input) session (pathname-name input)) output))

(defun compile-clos (output &key (session (kiln.compiler:make-session)))
  "Compiles CLOS (Clostrophilia and kiln's bootstrap) to the KIR module
OUTPUT, to be loaded after the kernel. SESSION must have compiled the
kernel."
  (write-module (compile-files *clos-files* session "clos"
                              ;; Named by Anatomicl, compiled later, and by
                              ;; nothing before it.
                              :extra-symbols '(closer-mop:ensure-class))
                output))

(defparameter *frontend-files*
  ;; The parts of the front end compiled for the target so far:
  ;; concrete syntax trees and Eclector's CST reader.
  (append
   (mapcar (lambda (name)
             (asdf:system-relative-pathname "concrete-syntax-tree" (format nil "~A.lisp" name)))
           '("packages" "generic-functions" "conditions" "utilities" "cst" "cons-cst"
             "listify" "cstify" "cst-from-expression" "quasiquotation" "reconstruct"
             "declarations" "body" "list-structure" "bindings"
             "condition-reporters-english"))
   (mapcar (lambda (name)
             (asdf:system-relative-pathname "eclector" (format nil "code/~A.lisp" name)))
           '("parse-result/package" "parse-result/client" "parse-result/generic-functions"
             "parse-result/labeled-objects" "parse-result/read"
             "concrete-syntax-tree/package" "concrete-syntax-tree/client"
             "concrete-syntax-tree/labeled-objects" "concrete-syntax-tree/read"))))

(defun compile-frontend (output &key (session (kiln.compiler:make-session)))
  "Compiles the front-end module to OUTPUT, loaded after the CLOS module.
SESSION must have compiled the kernel and CLOS."
  (write-module (compile-files *frontend-files* session "frontend") output))

(defun maclina-directory ()
  ;; Maclina is not loaded in the host (its system would be found among the
  ;; pinned dependencies).
  (asdf:system-source-directory (asdf:find-system "maclina")))

(defparameter *eval-files*
  ;; The eval module.
  (let ((cmd-renames '(("COMMON-MACRO-DEFINITIONS" . "KILN.CMD")))
        (cmd-dir "vendor/Common-macros/Common-macro-definitions/"))
    (flet ((ecclesia (name)
             (asdf:system-relative-pathname "ecclesia" (format nil "~A.lisp" name)))
           (cmd (name)
             (list :renames cmd-renames
                   (asdf:system-relative-pathname "kiln" (format nil "~A~A.lisp" cmd-dir name))))
           (eval-file (name)
             (asdf:system-relative-pathname "kiln" (format nil "lisp/target/eval/~A.lisp" name))))
      (append
       (mapcar #'ecclesia
               '("packages" "conditions" "condition-reporters-english" "argcount"
                 "list-structure" "form" "declarations" "lambda-list-parsing"
                 "lambda-list-canonicalization" "destructuring"
                 "canonicalized-destructuring"))
       (list (eval-file "packages"))
       ;; As common-macro-definitions-low.asd and -shared.asd.
       (mapcar (lambda (name) (cmd (format nil "Low/~A" name)))
               '("condition-types" "utilities" "when" "unless" "and" "or" "cond" "case"
                 "ecase" "return" "multiple-value-bind" "multiple-value-list"
                 "multiple-value-setq" "nth-value" "defvar" "expand-defmethod"
                 "expand-deftype" "expand-defpackage" "expand-defun" "expand-defclass"
                 "expand-defgeneric" "expand-declaim" "defsetf" "destructuring-bind"
                 "do-symbols" "lambda" "prog" "progstar" "prog1" "prog2" "handler-case"
                 "ignore-errors" "in-package" "iteration-support" "dolist" "dotimes" "do"
                 "dostar" "psetq" "restart-case" "check-type" "typecase" "etypecase"
                 "with-accessors" "with-input-from-string" "with-open-file"
                 "with-open-stream" "with-output-to-string" "with-simple-restart"
                 "with-slots"))
       (mapcar #'cmd
               '("utilities" "defmethod" "deftype" "defpackage" "defparameter" "defmacro"
                 "define-compiler-macro" "define-setf-expander" "defun" "defclass"
                 "defgeneric" "declaim" "ccase" "ctypecase" "decf" "incf" "pop" "psetf"
                 "push" "pushnew" "remf" "rotatef" "setf" "shiftf" "define-modify-macro"))
       (list (list :renames '(("KILN.MACROS" . "KILN.MACROS-TARGET"))
                   (asdf:system-relative-pathname "kiln" "lisp/macro-client.lisp"))
             (eval-file "macros"))
       ;; Trucler (trucler-base.asd, and the client class of
       ;; trucler-native.asd), then Maclina (maclina.asd: base, compile,
       ;; vm-shared, vm-native).
       (mapcar (lambda (name)
                 (asdf:system-relative-pathname "trucler-base" (format nil "~A.lisp" name)))
               '("packages" "query-functions" "query-class-accessors" "cloning-information"
                 "quasi-clone" "query-mixin-classes" "query-classes" "query-factories"
                 "merge-functions" "merge-methods" "low-level-augmentation-functions"
                 "augmentation-functions" "environment-builder" "macro-functions"
                 "conditions" "condition-reporters-english"))
       (mapcar (lambda (name)
                 (asdf:system-relative-pathname "trucler-native" (format nil "~A.lisp" name)))
               '("packages" "client" "methods"))
       ;; parse-macro.lisp's functions are called by the expander of
       ;; DESTRUCTURE-SYNTAX (compile.lisp).
       (mapcar (lambda (name)
                 (let ((path (merge-pathnames (format nil "~A.lisp" name) (maclina-directory))))
                   (if (string= name "compile/parse-macro")
                       (list :compile-time-too path)
                       path)))
               '("packages" "machine" "arg-conditions" "structures" "map-info" "link"
                 "access" "introspect"
                 "compile/package" "compile/conditions" "compile/misc-program-conditions"
                 "compile/parse-macro" "compile/unknown-reference-conditions"
                 "compile/compilation-unit" "compile/environment" "compile/compile"
                 "vm-shared" "vm-native"))
       (list (eval-file "evaluator")
             (eval-file "modules")
             (eval-file "compilation-unit")
             (eval-file "repl")
             (eval-file "server"))))))

(defun compile-eval (output &key (session (kiln.compiler:make-session)))
  "Compiles the eval module to OUTPUT, loaded after the CLOS module.
SESSION must have compiled the kernel and CLOS."
  (write-module (compile-files *eval-files* session "eval") output))

(defun system-files (name &key exclude)
  "The Lisp source files of the ASDF system NAME, in load order, without
those whose names are in EXCLUDE."
  (loop for c in (asdf:required-components (asdf:find-system name)
                                           :other-systems nil
                                           :goal-operation 'asdf:load-op
                                           :keep-operation 'asdf:compile-op)
        when (and (typep c 'asdf:cl-source-file)
                  (not (member (pathname-name (asdf:component-pathname c)) exclude
                               :test #'string=)))
          collect (asdf:component-pathname c)))

(defparameter *compiler-files*
  ;; The compiler module: the front end's remaining dependencies
  ;; (Trucler's reference environments, Clostrum,
  ;; Anatomicl), then kiln's compiler (M5.3).
  (append
     (system-files "trucler-reference")
     (list (asdf:system-relative-pathname "kiln" "lisp/target/compiler/environment.lisp"))
     ;; Not the documentation strings (documentation-utils).
     (system-files "clostrum" :exclude '("documentation"))
     (system-files "clostrum-basic")
     (system-files "clostrum-trucler")
     ;; Anatomicl, which expands DEFSTRUCT in cross compilation (lisp/structures.lisp).
     (system-files "anatomicl")
     ;; kiln's compiler (M5.3): its packages are the host's.
     (mapcar (lambda (name) (asdf:system-relative-pathname "kiln" (format nil "lisp/~A.lisp" name)))
             '("abi" "kir" "ir/data" "lower" "values" "primitives" "structures" "front" "cross"
               "ir/environment" "ir/convert" "ir/analyze" "ir/eval" "ir/lower"
               "target/compiler/client" "target/compiler/session"
               "target/compiler/dependencies" "target/compiler/cache" "target/compiler/native"))))

(defun compile-compiler (output &key (session (kiln.compiler:make-session)))
  "Compiles the compiler module to OUTPUT, loaded after the front-end and
eval modules. SESSION must have compiled the kernel, CLOS, the front end
and eval."
  (kiln.compiler::prepare-compiler-session session)
  (let* ((client (kiln.compiler::session-client session))
         (genv (trucler:global-environment
                client (kiln.compiler::session-environment session))))
    ;; The source files of a module, for tests that compile modules on
    ;; kiln (tests/m5/co-clos.lisp): (KILN.COMPILER::MODULE-FILES "clos").
    (kiln.compiler::host-macro
     client genv 'kiln.compiler::module-files
     (lambda (form env)
       (declare (ignore env))
       `',(module-file-names (second form)))))
  (write-module (compile-files *compiler-files* session "compiler") output))

(defun module-file-names (name)
  "The source files of the module NAME, as front-end takes them, with
namestrings for pathnames."
  (let ((files (cdr (assoc name
                           `(("kernel" . ,*kernel-files*) ("clos" . ,*clos-files*)
                             ("frontend" . ,*frontend-files*) ("eval" . ,*eval-files*)
                             ("compiler" . ,*compiler-files*))
                           :test #'string=))))
    (mapcar (lambda (file)
              (if (consp file)
                  (append (butlast file) (list (namestring (car (last file)))))
                  (namestring file)))
            files)))

(defun bootstrap-stage0 (directory)
  "Stage 0 of the bootstrap: compiles the five modules and the
build program (lisp/target/build.lisp) to NAME.kir in DIRECTORY, in one
session, and writes the build program's manifest there, modules.lisp-expr:
for each module, its name and source files. kiln0, linked from these
modules, runs the build program, which compiles the same modules and
itself as here."
  (let* ((dir (uiop:ensure-directory-pathname directory))
         (session (kiln.compiler:make-session))
         (build (asdf:system-relative-pathname "kiln" "lisp/target/build.lisp")))
    (flet ((out (name) (merge-pathnames (format nil "~A.kir" name) dir)))
      (compile-kernel (out "kernel") :session session)
      (compile-clos (out "clos") :session session)
      (compile-frontend (out "frontend") :session session)
      (compile-eval (out "eval") :session session)
      (compile-compiler (out "compiler") :session session)
      (compile-file-to-kir build (out "build") :session session))
    (write-manifest (merge-pathnames "modules.lisp-expr" dir) :programs (list build))
    dir))

(defun write-manifest (output &key programs)
  "Writes the build program's manifest (lisp/target/build.lisp) to OUTPUT:
the five modules and their source files, then each of the source files
PROGRAMS as a module named after the file, as compile-file-to-kir names
it. Run in OUTPUT's directory, the build program compiles them in that
order, in one session, to NAME.kir."
  (with-open-file (out output :direction :output :if-exists :supersede)
    (with-standard-io-syntax
      (let ((*print-readably* nil))
        (format out "~S~%"
                (append (mapcar (lambda (name) (cons name (module-file-names name)))
                                '("kernel" "clos" "frontend" "eval" "compiler"))
                        (mapcar (lambda (program)
                                  (list (pathname-name program) (namestring program)))
                                programs))))))
  output)
