;;; The compiler on kiln (docs/11 §8, M5.3): the front end and lower.lisp
;;; compile co-compile-input.lisp to KIR, which is printed. The output
;;; must be the module that SBCL made of that file in the same session
;;; (co-compile.same-kir names it, tools/test.sh).

(let ((session (kiln.compiler:make-session)))
  (multiple-value-bind (asts packages)
      ;; The undefined functions (the accessors of a DEFCLASS) are reported
      ;; in SBCL too.
      (handler-bind ((style-warning #'muffle-warning))
        (kiln.compiler:front-end (list "tests/m5/co-compile-input.lisp") session))
    (kiln.kir:print-module (kiln.compiler:compile-module asts "co-compile-input"
                                                         :session session
                                                         :defined-packages packages)
                           *standard-output*)))
