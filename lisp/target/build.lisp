;;;; kiln's build program (docs/11 §10). Linked with the five modules (the
;;;; kernel, CLOS, the front end, eval and the compiler), it compiles them
;;;; and itself again, in one cross compilation session, as SBCL compiles
;;;; them in stage 0 (kiln:bootstrap-stage0).
;;;;
;;;; Run in a directory holding modules.lisp-expr, which stage 0 writes: a
;;;; list of (NAME FILE...), the modules in order with their source files,
;;;; as KILN.COMPILER:FRONT-END takes them. Each module is written to
;;;; NAME.kir in that directory.

(let ((manifest (with-open-file (in "modules.lisp-expr") (read in)))
      (session (kiln.compiler:make-session :client-class 'kiln.compiler::cross-client))
      (start (get-internal-real-time)))
  (dolist (entry manifest)
    (let ((name (first entry))
          (files (rest entry))
          (extra-symbols '()))
      ;; As kiln:compile-kernel and kiln:compile-compiler.
      (when (string= name "kernel")
        (do-external-symbols (s '#:common-lisp) (push s extra-symbols)))
      (when (string= name "compiler")
        (kiln.compiler::prepare-compiler-session session))
      (let ((module
              ;; Undefined functions (accessors of DEFCLASS) are reported
              ;; as warnings, on *STANDARD-OUTPUT*.
              (handler-bind ((warning (lambda (w)
                                        (let ((r (find-restart 'muffle-warning w)))
                                          (when r (invoke-restart r))))))
                (multiple-value-bind (asts packages)
                    (kiln.compiler:front-end files session)
                  (kiln.compiler:compile-module asts name :session session
                                                          :defined-packages packages
                                                          :extra-symbols extra-symbols)))))
        (with-open-file (out (concatenate 'string name ".kir")
                             :direction :output :if-exists :supersede)
          (kiln.kir:print-module module out)))
      (format t "~A ~,1Fs~%" name
              (/ (- (get-internal-real-time) start) internal-time-units-per-second))
      (finish-output))))
