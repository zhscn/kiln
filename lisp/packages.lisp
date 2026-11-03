(defpackage #:kiln.abi
  (:use #:cl)
  (:documentation "Constants shared with the runtime. See docs/06-m0-abi.md.")
  (:export #:+fixnum-shift+ #:+tag-mask+ #:+tag-cons+ #:+tag-general+
           #:+kind-mask+ #:+kind-symbol+ #:+kind-function+ #:+kind-cons+
           #:+kind-simple-vector+
           #:+cons-bytes+ #:+cons-car+ #:+cons-cdr+
           #:+ctx-poll-flag+ #:+ctx-dynenv+
           #:+dyn-catch+ #:+dyn-unwind-protect+ #:+dynentry-size+
           #:+dyn-kind+ #:+dyn-prev+ #:+dyn-fp+ #:+dyn-tag+
           #:+dyn-pend-target+ #:+dyn-pend-value+
           #:+fobj-entry+
           #:+err-not-fixnum+ #:+err-overflow+ #:+err-wrong-nargs+
           #:+err-not-list+ #:+err-not-function+
           #:+reg-args+))

(defpackage #:kiln.kir
  (:use #:cl #:kiln.abi)
  (:documentation "Building and printing KIR, the interchange format with kiln-cg.")
  (:export #:kmodule #:make-kmodule #:kmodule-name
           #:*module* #:*func*
           #:module-import-func #:module-import-data #:module-data
           #:module-func #:module-init
           #:with-function #:new-var #:new-block #:new-slot
           #:emit #:start-block #:current-block-terminated-p
           #:print-module))

(defpackage #:kiln.sys
  (:use)
  (:documentation "Implementation-specific operators available to compiled code.")
  (:export #:%gc #:%gc-count #:%call-on-new-stack))

(defpackage #:kiln.m0
  (:use #:cl #:kiln.abi #:kiln.kir #:kiln.sys)
  (:documentation "Scaffolding compiler for a small Lisp subset (M0/M1).
It will be replaced by the Common-boot based front end in M2.")
  (:export #:compile-forms #:m0-compile-error))

(defpackage #:kiln
  (:use #:cl)
  (:export #:compile-file-to-kir))

(defpackage #:kiln-user
  (:use #:cl #:kiln.sys)
  (:documentation "Package in which M0 test sources are read."))
