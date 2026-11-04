(defpackage #:kiln.abi
  (:use #:cl)
  (:documentation "Constants shared with the runtime. See docs/06-m0-abi.md.")
  (:export #:+fixnum-shift+ #:+tag-mask+ #:+tag-cons+ #:+tag-general+
           #:+kind-mask+ #:+kind-symbol+ #:+kind-function+ #:+kind-cons+
           #:+kind-simple-vector+ #:+kind-string+ #:+kind-bignum+
           #:+immediate-mask+ #:+character-tag+ #:+character-shift+ #:+char-code-limit+
           #:+symbol-name+ #:+symbol-package+ #:+symbol-plist+ #:+vector-data+
           #:+symbol-function+ #:+symbol-value+ #:+symbol-tls-index+ #:+unbound+
           #:+length-shift+ #:+fobj-env+
           #:+cons-bytes+ #:+cons-car+ #:+cons-cdr+
           #:+ctx-poll-flag+ #:+ctx-dynenv+ #:+ctx-values+ #:+values-max+ #:+ctx-values-live+ #:+ctx-tls+ #:+no-tls-value+
           #:+dyn-catch+ #:+dyn-unwind-protect+ #:+dyn-exit-point+ #:+dyn-bind+ #:+dyn-progv+ #:+dynentry-size+
           #:+dyn-kind+ #:+dyn-prev+ #:+dyn-fp+ #:+dyn-tag+
           #:+dyn-pend-target+ #:+dyn-pend-value+
           #:+fobj-entry+
           #:+err-not-fixnum+ #:+err-overflow+ #:+err-wrong-nargs+
           #:+err-not-list+ #:+err-not-function+
           #:+err-undefined-function+ #:+err-unbound-variable+ #:+err-not-symbol+
           #:+err-odd-keywords+ #:+err-unknown-keyword+
           #:+err-not-character+ #:+err-not-string+ #:+err-not-vector+
           #:+err-index+ #:+err-not-sequence+ #:+err-not-integer+ #:+err-division-by-zero+
           #:+reg-args+))

(defpackage #:kiln.kir
  (:use #:cl #:kiln.abi)
  (:documentation "Building and printing KIR, the interchange format with kiln-cg.")
  (:export #:kmodule #:make-kmodule #:kmodule-name
           #:*module* #:*func*
           #:module-import-func #:module-import-data #:module-data
           #:module-func #:module-init #:module-root #:module-shared
           #:with-function #:new-var #:new-block #:new-slot
           #:emit #:start-block #:current-block-terminated-p
           #:print-module))

(defpackage #:kiln.sys
  (:use)
  (:documentation "Implementation-specific operators available to compiled code.")
  (:export #:%gc #:%gc-count #:%call-on-new-stack #:%primop))

(defpackage #:kiln.compiler
  (:use #:cl #:kiln.abi #:kiln.kir)
  (:local-nicknames (#:ico #:iconoclast)
                    (#:cb #:common-boot)
                    (#:cbe #:common-boot-hir-evaluator)
                    (#:cbah #:common-boot-ast-to-hir)
                    (#:cmd #:common-macro-definitions)
                    (#:clo #:clostrum))
  (:documentation "The compiler: Common-boot front end, lowering to KIR.")
  (:export #:front-end #:make-session #:compile-module #:kiln-compile-error))

(defpackage #:kiln
  (:use #:cl)
  (:export #:compile-file-to-kir #:compile-kernel))

(defpackage #:kiln.kernel
  (:use #:cl #:kiln.sys)
  (:documentation "Package of the target kernel sources (lisp/target/)."))

(defpackage #:kiln-user
  (:use #:cl #:kiln.sys)
  (:documentation "Package in which test sources are read."))
