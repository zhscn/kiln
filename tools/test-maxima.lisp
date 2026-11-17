(in-package #:cl-user)

(defparameter *maxima-test-source* (kiln.sys:getenv "KILN_MAXIMA_SOURCE"))
(defparameter *maxima-binary-directory* (kiln.sys:getenv "KILN_MAXIMA_BUILD"))
(assert (and *maxima-test-source* *maxima-binary-directory*))

;; MK's loader is only needed to drive the build. Keep its initialization
;; interpreted; the Maxima files themselves use the native compiler.
(let ((kiln.kernel::*compile-function* nil)
      (kiln.kernel::*eval-function* nil))
  (load (merge-pathnames "lisp-utils/defsystem.lisp" *maxima-test-source*)))
(mk:add-registry-location (merge-pathnames "src/" *maxima-test-source*))
(mk:find-system "maxima" :load)

;; MK does not otherwise reject COMPILE-FILE's failure return value.
(labels ((install-compiler (component)
           (setf (mk::component-compiler component)
                 (lambda (file &rest options)
                   (format t "~&MAXIMA-COMPILE ~A~%" file)
                   (force-output)
                   (multiple-value-bind (output warnings failure)
                       (apply #'compile-file file options)
                     (when failure (error "Maxima compilation failed: ~A" file))
                     (values output warnings failure))))
           (mapc #'install-compiler (mk::component-components component))))
  (install-compiler (mk:find-system "maxima" :error)))

(mk:operate-on-system "maxima" :compile :force :new-source-and-dependents
                      :verbose t :bother-user-if-no-binary nil
                      :load-source-if-no-binary nil)
(format t "~&MAXIMA-BUILD-COMPLETED~%")
(force-output)

(in-package #:maxima)
(setf *maxima-load-init-files* nil)
(initialize-runtime-globals)
(setf *debugger-hook* nil)
(assert (string= *maxima-lispname* "kiln"))
(assert (member :lisp-unicode-capable *features*))
(assert (= (getpid) (kiln.sys:getpid)))
(dolist (code '(160 8203 8239))
  (assert (= (meval* (meval* (list '($parse_string)
                                  (format nil "1+~C2;" (code-char code))))) 3)))
(let ((path (merge-pathnames "startup-encoding.txt" cl-user::*maxima-binary-directory*)))
  (unwind-protect
       (progn
         (with-output-to-string (*standard-output*)
           (let ((stream ($openw (namestring path))))
             (write-line "encoding" stream)
             (close stream)))
         (with-open-file (stream path)
           (assert (string= (read-line stream) "encoding"))))
    (when (probe-file path) (delete-file path))))
(assert (equal (maxima-getenv "HOME") (kiln.sys:getenv "HOME")))
(assert (equal (intl::getenv "HOME") (kiln.sys:getenv "HOME")))
(assert (equal (command-line::get-application-args)
               (rest (kiln.sys:command-line-arguments))))
(assert (eq *read-default-float-format* 'double-float))
(assert (= (meval* '((mplus) 1 2)) 3))
(format t "~&MAXIMA-STARTUP-CHECKS-COMPLETED~%")
(force-output)

(unless (kiln.sys:getenv "KILN_MAXIMA_BUILD_ONLY")
  (let* ((selected (kiln.sys:getenv "KILN_MAXIMA_TEST"))
         (tests (when selected (list '(mlist) selected))))
    (apply #'$run_testsuite
           (append (when tests (list (list '(mequal) '$tests tests)))
                   (when (kiln.sys:getenv "KILN_MAXIMA_SHARE")
                     (list (list '(mequal) '$share_tests
                                 (if (equal (kiln.sys:getenv "KILN_MAXIMA_SHARE") "only")
                                     '$only t))))
                   (when (kiln.sys:getenv "KILN_MAXIMA_DISPLAY_ALL")
                     (list (list '(mequal) '$display_all t))))))
  (format t "~&MAXIMA-TEST-OP-COMPLETED~%")
  (force-output))
t
