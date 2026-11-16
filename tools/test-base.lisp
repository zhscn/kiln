(in-package :cl-user)

(assert (eq kiln.compiler::*compiler-pipeline* :mir))

(defun test-environment (name)
  (let ((value (kiln.kernel::sys-string 10 (kiln.kernel::string-octets name))))
    (and (stringp value) (plusp (length value)) value)))

;; Cross-compiled test files use the runtime diagnostic printer for
;; one-argument PRINT. Compile the same observation helper into the base;
;; runtime EVAL and explicit stream printing retain the standard printer.
(setf (gethash 'test-observation kiln.compiler::*primitives*)
      (gethash 'print kiln.compiler::*primitives*))
(compile 'test-observation '(lambda (object) (test-observation object)))
(remhash 'test-observation kiln.compiler::*primitives*)

(defun test-print-expander (form environment)
  (declare (ignore environment))
  (if (= (length form) 2) `(test-observation ,(second form)) form))

(defun test-unhandled-error (condition hook)
  (declare (ignore hook))
  (format *error-output* "~&~A~%" condition)
  (kiln.sys:exit 1))

(defun run-file-test ()
  ;; A handler around the test would intercept errors intended for an
  ;; inner debugger hook, such as the REPL's ABORT restart.
  (let ((*debugger-hook* #'test-unhandled-error)
        (*compile-verbose* nil) (*compile-print* nil)
        (*load-verbose* nil) (*load-print* nil))
    (if (equal (test-environment "KILN_TEST_PHASE") "compile")
        (progn
          (setf (compiler-macro-function 'print) #'test-print-expander)
          (multiple-value-bind (output warnings failure)
              (compile-file (test-environment "KILN_TEST_SOURCE")
                            :output-file (test-environment "KILN_TEST_FASL"))
            (declare (ignore warnings))
            (kiln.sys:exit (if (and output (not failure)) 0 1))))
        (let ((kiln.kernel::*compile-function*
                (if (equal (test-environment "KILN_TEST_EVAL") "hir")
                    nil kiln.kernel::*compile-function*))
              (kiln.kernel::*eval-function*
                (if (equal (test-environment "KILN_TEST_EVAL") "hir")
                    nil kiln.kernel::*eval-function*)))
          (load (test-environment "KILN_TEST_FASL"))
          (kiln.sys:exit 0)))))

(kiln.sys:save-image (test-environment "KILN_TEST_BASE")
                     :toplevel #'run-file-test)
