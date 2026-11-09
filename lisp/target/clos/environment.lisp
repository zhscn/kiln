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
