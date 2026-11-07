;;;; Heap images (docs/15): KILN.SYS:SAVE-IMAGE, as SBCL's
;;;; SAVE-LISP-AND-DIE, without the dying.

(in-package #:kiln.kernel)

(defvar kiln.sys:*save-hooks* '()
  "Functions called, in order, before an image is saved.")

(defvar kiln.sys:*init-hooks* '()
  "Functions called, in order, when an executable starts from an image,
before its toplevel function.")

(defun kiln.sys:save-image (pathname &key (toplevel (lambda () nil)) executable)
  "Writes the state of the image to PATHNAME: everything reachable from
global definitions and the global values of special variables (dynamic
bindings and the stack are not saved). Started with the environment
variable KILN_IMAGE naming the file, the same executable calls TOPLEVEL
instead of running its modules' initialization. With EXECUTABLE true,
PATHNAME is a copy of the executable with the image appended, which
starts from it by itself. Returns PATHNAME; the process continues."
  (mapc #'funcall kiln.sys:*save-hooks*)
  (finish-output *standard-output*)
  (finish-output *error-output*)
  (let ((start toplevel))
    (when (eql 1 (kiln.sys:%primop
                  :save-image
                  (string-octets (native-namestring pathname))
                  (lambda ()
                    (mapc #'funcall kiln.sys:*init-hooks*)
                    (funcall start))
                  (if executable t nil)))
      (error "Cannot save an image to ~a" pathname)))
  pathname)

;;; The process an image starts in has its own working directory.
(push (lambda () (setf *default-pathname-defaults* (current-directory)))
      kiln.sys:*init-hooks*)
