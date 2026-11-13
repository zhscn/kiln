;;; kiln compiles its kernel: a cross compilation, in a
;;; compile-time environment of its own, as SBCL's. The KIR printed must be
;;; the kernel module that SBCL made in the same session (co-kernel.same-kir).

;;; Compiler diagnostics are separate from the serialized program.
(handler-bind ((warning #'muffle-warning))
  (let ((session (kiln.compiler:make-session :client-class 'kiln.compiler::cross-client))
        (symbols '()))
    ;; As kiln:compile-kernel: every standard symbol exists at run time.
    (do-external-symbols (s '#:common-lisp) (push s symbols))
    (multiple-value-bind (asts packages)
        ;; The files as SBCL names them: the names are in the debug info.
        (kiln.compiler:front-end (kiln.compiler::module-files "kernel") session)
      (kiln.kir:print-module (kiln.compiler:compile-module asts "kernel" :session session
                                                           :defined-packages packages
                                                           :extra-symbols symbols)
                             *standard-output*))))
