;;; kiln compiles its CLOS module (docs/11 §9, M5.4): a cross compilation,
;;; kernel first, then CLOS in the same session, as SBCL compiles them. The
;;; KIR printed must be the CLOS module that SBCL made (co-clos.same-kir).
;;; Slow (about 20 minutes, a 2 GiB heap): run only when named
;;; (co-clos.slow).

(let ((session (kiln.compiler:make-session :client-class 'kiln.compiler::cross-client))
      (symbols '()))
  (do-external-symbols (s '#:common-lisp) (push s symbols))
  (multiple-value-bind (asts packages)
      (kiln.compiler:front-end (kiln.compiler::module-files "kernel") session)
    (kiln.compiler:compile-module asts "kernel" :session session
                                                :defined-packages packages
                                                :extra-symbols symbols))
  (multiple-value-bind (asts packages)
      (kiln.compiler:front-end (kiln.compiler::module-files "clos") session)
    (kiln.kir:print-module (kiln.compiler:compile-module asts "clos" :session session
                                                         :defined-packages packages)
                           *standard-output*)))
