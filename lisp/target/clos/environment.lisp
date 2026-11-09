;;;; Implementation, operating system, and machine information.

(in-package #:kiln.kernel)

(defun environment-information (which)
  (let ((value (sys-string 20 which)))
    (and (stringp value) value)))

(defun lisp-implementation-type () "kiln")

(defun lisp-implementation-version () (environment-information 0))

(defun software-type () (environment-information 1))

(defun software-version () (environment-information 2))

(defun machine-instance () (environment-information 3))

(defun machine-type () (environment-information 4))

(defun machine-version () (environment-information 5))

(defvar *short-site-name* nil)
(defvar *long-site-name* nil)

(defun short-site-name () *short-site-name*)

(defun long-site-name () *long-site-name*)

(defun room (&optional (detail :default))
  (check-type detail (member nil t :default))
  (let ((used (sys 22 0))
        (free (sys 22 1))
        (total (sys 22 2))
        (collections (kiln.sys:%gc-count)))
    (format t "~&Dynamic space: ~D bytes used.~%" used)
    (when detail
      (format t "Heap capacity: ~D bytes; free: ~D bytes.~%Completed collections: ~D~%"
              total free collections))
    (when (eq detail t)
      (format t "Registered static root slots: ~D~%" (sys 22 3))))
  (values))
