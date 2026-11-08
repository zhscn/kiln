;;;; kiln's build program. Linked with the five modules (the
;;;; kernel, CLOS, the front end, eval and the compiler), it compiles them
;;;; and itself again, in one cross compilation session, as SBCL compiles
;;;; them in stage 0 (kiln:bootstrap-stage0).
;;;;
;;;; Run in a directory holding modules.lisp-expr, which stage 0 writes: a
;;;; list of (NAME FILE...), the modules in order with their source files,
;;;; as KILN.COMPILER:FRONT-END takes them. Each module is written to
;;;; NAME.kir in that directory. Programs (tests, the build program itself)
;;;; are modules too, after the five (kiln:write-manifest).
;;;;
;;;; With the environment variable KILN_SAVE_IMAGE naming a file, the
;;;; program saves a heap image there once it has compiled the five
;;;; modules. Started from that image, it reads the manifest
;;;; again and compiles the programs only: tools/test.sh does so when kiln
;;;; compiles the tests.

(defparameter *build-modules* '("kernel" "clos" "frontend" "eval" "compiler"))

(defun build-module (entry manifest session start)
  (let ((name (first entry))
        (files (rest entry))
        (extra-symbols '()))
    ;; As kiln:compile-kernel, kiln:compile-clos and kiln:compile-compiler.
    (when (string= name "kernel")
      (do-external-symbols (s '#:common-lisp) (push s extra-symbols)))
    (when (string= name "clos")
      (push 'closer-mop:ensure-class extra-symbols))
    (when (string= name "compiler")
      (kiln.compiler::prepare-compiler-session session)
      ;; As kiln:compile-compiler: (KILN.COMPILER::MODULE-FILES NAME),
      ;; for programs that compile modules (tests/m5/co-clos.lisp), is
      ;; the source files of the module NAME, here from the manifest.
      (let* ((client (kiln.compiler::session-client session))
             (genv (trucler:global-environment
                    client (kiln.compiler::session-environment session))))
        (kiln.compiler::host-macro
         client genv 'kiln.compiler::module-files
         (lambda (form env)
           (declare (ignore env))
           `',(rest (assoc (second form) manifest :test #'string=))))))
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
    (finish-output)))

(defun read-build-manifest ()
  (with-open-file (in "modules.lisp-expr") (read in)))

(defun build-programs (session)
  "Compiles the entries of the manifest after the five modules, which
SESSION has compiled."
  (let ((manifest (read-build-manifest))
        (start (get-internal-real-time)))
    (dolist (entry manifest)
      (unless (member (first entry) *build-modules* :test #'string=)
        (build-module entry manifest session start)))))

(defun getenv (name)
  (let ((value (kiln.kernel::sys-string 10 (kiln.kernel::string-octets name))))
    (and (stringp value) (plusp (length value)) value)))

;;; With KILN_SERVE set, the program serves the back-end protocol on its
;;; standard input and output instead.
(if (getenv "KILN_SERVE")
    (kiln.sys:serve)
    (let ((manifest (read-build-manifest))
          (session (kiln.compiler:make-session :client-class 'kiln.compiler::cross-client))
          (start (get-internal-real-time))
          (image (getenv "KILN_SAVE_IMAGE")))
      (dolist (entry manifest)
        (build-module entry manifest session start)
        (when (and image (string= (first entry) "compiler"))
          (kiln.sys:save-image image :toplevel (lambda () (build-programs session)))
          (format t "saved ~A~%" image)
          (finish-output)))))
