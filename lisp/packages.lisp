(defpackage #:kiln.abi
  (:use #:cl)
  (:documentation "Constants shared with the runtime. See docs/06-m0-abi.md.")
  (:export #:+fixnum-shift+ #:+tag-mask+ #:+tag-cons+ #:+tag-general+
           #:+kind-mask+ #:+kind-symbol+ #:+kind-function+ #:+kind-cons+
           #:+kind-simple-vector+ #:+kind-string+ #:+kind-bignum+
           #:+kind-ratio+ #:+kind-double+ #:+kind-complex+ #:+single-float-tag+
           #:+kind-instance+ #:+kind-funcallable-instance+ #:+kind-rack+ #:+function-kind-mask+
           #:+immediate-mask+ #:+character-tag+ #:+character-shift+ #:+char-code-limit+
           #:+symbol-name+ #:+symbol-package+ #:+symbol-plist+ #:+symbol-setf-function+ #:+vector-data+
           #:+symbol-function+ #:+symbol-value+ #:+symbol-tls-index+ #:+unbound+
           #:+length-shift+ #:+fobj-env+
           #:+cons-bytes+ #:+cons-car+ #:+cons-cdr+
           #:+ctx-poll-flag+ #:+ctx-dynenv+ #:+ctx-values+ #:+values-max+ #:+ctx-values-live+ #:+ctx-alloc-cursor+ #:+ctx-alloc-limit+ #:+ctx-stack-limit+ #:+ctx-tls+ #:+no-tls-value+
           #:+dyn-catch+ #:+dyn-unwind-protect+ #:+dyn-exit-point+ #:+dyn-bind+ #:+dyn-progv+ #:+dynentry-size+
           #:+dyn-kind+ #:+dyn-prev+ #:+dyn-fp+ #:+dyn-tag+
           #:+dyn-pend-target+ #:+dyn-pend-value+
           #:+fobj-entry+
           #:+err-not-fixnum+ #:+err-overflow+ #:+err-wrong-nargs+
           #:+err-not-list+ #:+err-not-function+
           #:+err-undefined-function+ #:+err-unbound-variable+ #:+err-not-symbol+
           #:+err-odd-keywords+ #:+err-unknown-keyword+
           #:+err-not-character+ #:+err-not-string+ #:+err-not-vector+
           #:+err-index+ #:+err-not-sequence+ #:+err-not-integer+ #:+err-division-by-zero+ #:+err-not-number+ #:+err-bad-type+ #:+err-lisp-error+ #:+err-undefined-setf-function+ #:+unbound-slot+
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
  (:export #:%gc #:%gc-count #:%call-on-new-stack #:%primop
           ;; Targets of the DEFCLASS, DEFGENERIC and DEFMETHOD expansions
           ;; (lisp/target/clos/early.lisp).
           #:%defclass #:%defgeneric #:%defmethod #:%method-function
           #:%method-fast-function
           ;; The read-eval-print loop (lisp/target/eval/repl.lisp).
           #:repl
           ;; Heap images (lisp/target/clos/image.lisp, docs/15).
           #:save-image #:*save-hooks* #:*init-hooks*
           ;; Frames and backtraces (lisp/target/clos/debug.lisp, docs/17).
           #:frame-list #:frame-name #:frame-source #:frame-variables #:frame-pc
           #:source-line #:print-frame #:print-backtrace #:exit
           ;; The back-end protocol (lisp/target/eval/server.lisp, docs/17 §4).
           #:serve
           ;; Dependency tracking (lisp/target/compiler/dependencies.lisp,
           ;; docs/18).
           #:dependents #:dependencies #:*recompile-verbose* #:stale-definition
           #:stack-exhausted
           ;; The sampling profiler (lisp/target/clos/profile.lisp).
           #:start-profiler #:stop-profiler #:profile-samples #:profile-report
           #:write-folded-stacks #:with-profiling))

(defpackage #:kiln.macros
  (:use #:cl)
  (:local-nicknames (#:cmd #:common-macro-definitions))
  (:documentation "kiln's Common-macros client (macro-client.lisp).")
  (:export #:macro-client))

(defpackage #:kiln.compiler
  (:use #:cl #:kiln.abi #:kiln.kir)
  (:local-nicknames (#:ico #:iconoclast)
                    (#:cb #:common-boot)
                    (#:cbe #:common-boot-hir-evaluator)
                    (#:cbah #:common-boot-ast-to-hir)
                    (#:cmd #:common-macro-definitions)
                    (#:clo #:clostrum))
  (:documentation "The compiler: Common-boot front end, lowering to KIR.")
  (:export #:front-end #:make-session #:compile-module #:kiln-compile-error
           #:use-host-macros))

(defpackage #:kiln
  (:use #:cl)
  (:export #:compile-file-to-kir #:compile-kernel #:compile-clos #:compile-frontend
           #:compile-compiler
           #:compile-eval #:bootstrap-stage0 #:write-manifest))

(defpackage #:kiln.structures
  (:use)
  (:documentation "Variables holding the classes of structures (lisp/structures.lisp)."))

(defpackage #:kiln.kernel
  (:use #:cl #:kiln.sys)
  (:documentation "Package of the target kernel sources (lisp/target/)."))

(defpackage #:kiln-user
  (:use #:cl #:kiln.sys)
  (:documentation "Package in which test sources are read."))
