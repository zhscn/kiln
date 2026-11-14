;;; The compiler on kiln: the front end and lower.lisp
;;; compile co-compile-input.lisp to KIR, which is printed. The output
;;; must be the module that SBCL made of that file in the same session
;;; (co-compile.same-kir names it, tools/test.sh).

(let ((kiln.compiler::*compiler-pipeline*
        (if (equal (kiln.kernel::sys-string
                    10 (kiln.kernel::string-octets "KILN_BUILD_PIPELINE"))
                   "mir")
            :mir :hir)))
  (declare (special kiln.compiler::*compiler-pipeline*))
  (let ((session (kiln.compiler:make-session)))
    (multiple-value-bind (asts packages)
        ;; The undefined functions (the accessors of a DEFCLASS) are reported
        ;; in SBCL too.
        (handler-bind ((style-warning #'muffle-warning))
          ;; The absolute name, as tools/test.sh gives it to SBCL: names
          ;; are in the debug info.
          (kiln.compiler:front-end
           (list (namestring (truename "tests/m5/co-compile-input.lisp"))) session))
      (kiln.kir:print-module (kiln.compiler:compile-module asts "co-compile-input"
                                    :pipeline kiln.compiler::*compiler-pipeline*
                                                           :session session
                                                           :defined-packages packages)
                             *standard-output*)))
)
