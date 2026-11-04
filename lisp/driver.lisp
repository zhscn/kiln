(in-package #:kiln)

(defparameter *kernel-files*
  (mapcar (lambda (name)
            (asdf:system-relative-pathname "kiln" (format nil "lisp/target/~A.lisp" name)))
          '("kernel" "early" "types" "sequences"))
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
            "reader-error-define-condition" "simple-condition-define-condition"
            "simple-error-define-condition" "type-error-define-condition"
            "simple-type-error-define-condition" "simple-warning-define-condition"
            "storage-condition-define-condition" "stream-error-define-condition"
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
  ;; does the rest (docs/10 §14).
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
         (kiln-clos-file "trivial-package-locks")
         ;; Trinsic, for the interfaces of Cyclosis and the printer modules.
         (asdf:system-relative-pathname "trinsic" "code/interface.lisp"))
   *cyclosis-files*
   (list (kiln-clos-file "streams")))
  "Sources of the CLOS module, in load order (docs/10 §7).")

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
  (write-module (compile-files *clos-files* session "clos") output))
