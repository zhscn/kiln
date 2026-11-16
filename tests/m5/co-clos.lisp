;;; kiln compiles kernel and CLOS in one cross-compilation session.
;;; The diagnostic KIR must match the host-built CLOS module.
;;; Slow: run only when named (co-clos.slow).

(let ((kiln.compiler::*compiler-pipeline* :mir))
  (declare (special kiln.compiler::*compiler-pipeline*))
  (handler-bind ((warning #'muffle-warning))
    (let ((session (kiln.compiler:make-session :client-class 'kiln.compiler::cross-client))
          (symbols '()))
      (do-external-symbols (symbol '#:common-lisp) (push symbol symbols))
      (multiple-value-bind (asts packages)
          (kiln.compiler:front-end (kiln.compiler::module-files "kernel") session)
        (kiln.compiler:compile-module asts "kernel" :pipeline kiln.compiler::*compiler-pipeline*
                                     :session session :defined-packages packages
                                     :extra-symbols symbols))
      (multiple-value-bind (asts packages)
          (kiln.compiler:front-end (kiln.compiler::module-files "clos") session)
        (kiln.kir:print-module
         (kiln.compiler:compile-module asts "clos" :pipeline kiln.compiler::*compiler-pipeline*
                                      :session session :defined-packages packages
                                      :extra-symbols '(closer-mop:ensure-class))
         *standard-output*)))))
