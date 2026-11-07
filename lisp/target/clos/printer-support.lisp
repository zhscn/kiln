;;;; What the printer (Incless) needs from the rest of CL:
;;;; the printer variables, WITH-STANDARD-IO-SYNTAX, and READTABLE-CASE
;;;; and GET-MACRO-CHARACTER until the reader is loaded (reader.lisp
;;;; redefines them).

(in-package #:clostrophilia)

(defvar *print-array* t)
(defvar *print-base* 10)
(defvar *print-case* :upcase)
(defvar *print-circle* nil)
(defvar *print-escape* t)
(defvar *print-gensym* t)
(defvar *print-length* nil)
(defvar *print-level* nil)
(defvar *print-lines* nil)
(defvar *print-miser-width* nil)
(defvar *print-pprint-dispatch* nil)
(defvar *print-pretty* nil)
(defvar *print-radix* nil)
(defvar *print-readably* nil)
(defvar *print-right-margin* nil)
(defvar *read-base* 10)
(defvar *read-default-float-format* 'single-float)
(defvar *read-eval* t)
(defvar *read-suppress* nil)
(defvar *readtable* nil)
;;; Eclector's standard readtable, once the reader is loaded (reader.lisp).
;;; Also at compile time: macro expanders use WITH-STANDARD-IO-SYNTAX.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar kiln.kernel::*standard-readtable* nil)
  ;; Inravina's standard pprint dispatch table (pprint.lisp).
  (defvar kiln.kernel::*standard-pprint-dispatch* nil))

(defun readtable-case (readtable)
  (declare (ignore readtable))
  :upcase)

(defmacro with-standard-io-syntax (&body body)
  `(let ((*package* (find-package "COMMON-LISP-USER"))
         (*print-array* t) (*print-base* 10) (*print-case* :upcase)
         (*print-circle* nil) (*print-escape* t) (*print-gensym* t)
         (*print-length* nil) (*print-level* nil) (*print-lines* nil)
         (*print-miser-width* nil) (*print-pprint-dispatch* kiln.kernel::*standard-pprint-dispatch*)
         (*print-pretty* nil) (*print-radix* nil) (*print-readably* t)
         (*print-right-margin* nil) (*read-base* 10)
         (*read-default-float-format* 'single-float) (*read-eval* t)
         (*read-suppress* nil) (*readtable* kiln.kernel::*standard-readtable*))
     ,@body))

;;; TYPE-OF of a standard instance (generic functions included): its
;;; class's name.
(setf kiln.kernel::*instance-type-of*
      (lambda (object)
        (if (instancep object) (class-name (class-of object)) t)))

;;; The macro characters of the standard syntax (the printer asks whether
;;; a symbol's name must be quoted). There is no reader at run time yet,
;;; so the "functions" are just true.
(defun get-macro-character (char &optional readtable)
  (declare (ignore readtable))
  (cond ((find char "\"'(),;`") (values t nil))
        ((char= char #\#) (values t t))
        (t (values nil nil))))
