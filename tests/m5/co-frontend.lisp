;;; kiln compiles its front-end module: kernel, CLOS,
;;; then the front end in one cross compilation session, as SBCL compiles
;;; them. The KIR printed must be the front-end module that SBCL made
;;; (co-frontend.same-kir). Slow: run only when named (co-frontend.slow).

(let ((kiln.compiler::*compiler-pipeline*
        (if (equal (kiln.kernel::sys-string
                    10 (kiln.kernel::string-octets "KILN_BUILD_PIPELINE"))
                   "mir")
            :mir :hir)))
  (declare (special kiln.compiler::*compiler-pipeline*))
  (let ((session (kiln.compiler:make-session :client-class 'kiln.compiler::cross-client))
        (symbols '()))
    (do-external-symbols (s '#:common-lisp) (push s symbols))
    (flet ((compile-files (name files &rest args)
             ;; Undefined functions (accessors of DEFCLASS) are reported as
             ;; warnings, on *STANDARD-OUTPUT*.
             (handler-bind ((warning (lambda (w)
                                       (let ((r (find-restart 'muffle-warning w)))
                                         (when r (invoke-restart r))))))
               (multiple-value-bind (asts packages)
                   (kiln.compiler:front-end files session)
                 (apply #'kiln.compiler:compile-module asts name
                                    :pipeline kiln.compiler::*compiler-pipeline* :session session
                                                           :defined-packages packages
                                                           args)))))
      (compile-files "kernel" (kiln.compiler::module-files "kernel") :extra-symbols symbols)
      (compile-files "clos" (kiln.compiler::module-files "clos"))
      (kiln.kir:print-module (compile-files "frontend" (kiln.compiler::module-files "frontend")) *standard-output*)))
)
