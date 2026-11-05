;;; kiln compiles its kernel (docs/11 §9, M5.4): a cross compilation, in a
;;; compile-time environment of its own, as SBCL's. The KIR printed must be
;;; the kernel module that SBCL made in the same session (co-kernel.same-kir).

(let ((session (kiln.compiler:make-session :client-class 'kiln.compiler::cross-client))
      (symbols '()))
  ;; As kiln:compile-kernel: every standard symbol exists at run time.
  (do-external-symbols (s '#:common-lisp) (push s symbols))
  (multiple-value-bind (asts packages)
      (kiln.compiler:front-end (list "lisp/target/kernel.lisp" "lisp/target/early.lisp"
                                     "lisp/target/types.lisp" "lisp/target/sequences.lisp")
                               session)
    (kiln.kir:print-module (kiln.compiler:compile-module asts "kernel" :session session
                                                         :defined-packages packages
                                                         :extra-symbols symbols)
                           *standard-output*)))
