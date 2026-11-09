;;;; Shared pathname and dynamic state for file compilation.

(in-package #:kiln.kernel)

(defvar *compile-file-pathname* nil)
(defvar *compile-file-truename* nil)
(defvar *compile-print* nil)
(defvar *compile-verbose* t)

(defun compile-file-pathname (input-file &key (output-file nil output-file-p)
                                            &allow-other-keys)
  (let* ((input (pathname input-file))
         (output (when output-file-p (pathname output-file)))
         (location (if (or (not output)
                           (member (pathname-directory output) '(nil :unspecific)))
                       input output))
         (name (and output (pathname-name output)))
         (type (and output (pathname-type output))))
    (merge-pathnames
     (make-pathname :host (pathname-host location)
                    :device (pathname-device location)
                    :directory (pathname-directory location)
                    :name (if (member name '(nil :unspecific)) (pathname-name input) name)
                    :type (or type (if (typep location 'logical-pathname) "FASL" "fasl"))))))
