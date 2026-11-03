(defpackage #:kiln.abi
  (:use #:cl)
  (:documentation "Constants shared with the runtime. See docs/06-m0-abi.md.")
  (:export #:+fixnum-shift+ #:+tag-general+
           #:+kind-symbol+ #:+kind-function+
           #:+ctx-poll-flag+ #:+ctx-dynenv+
           #:+dyn-catch+ #:+dyn-unwind-protect+ #:+dynentry-size+
           #:+dyn-kind+ #:+dyn-prev+ #:+dyn-fp+ #:+dyn-tag+
           #:+fobj-entry+
           #:+err-not-fixnum+ #:+err-overflow+ #:+err-wrong-nargs+
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

(defpackage #:kiln.m0
  (:use #:cl #:kiln.abi #:kiln.kir)
  (:documentation "M0 scaffolding compiler for a small Lisp subset.
It will be replaced by the Common-boot based front end in M2.")
  (:export #:compile-forms #:m0-compile-error))

(defpackage #:kiln
  (:use #:cl)
  (:export #:compile-file-to-kir))

(defpackage #:kiln-user
  (:use #:cl)
  (:documentation "Package in which M0 test sources are read."))
