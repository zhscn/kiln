;;;; The reader: Eclector, with kiln's client and the CL
;;;; interface. Eclector's sources are read into the host's Eclector
;;;; packages, in which ECLECTOR.READTABLE shadows the CL readtable
;;;; functions and *READTABLE*; the CL functions here call Eclector's, and
;;;; the client makes Eclector use CL:*READTABLE*.
;;;;
;;;; Readtables are Eclector's simple readtables, whose class has
;;;; CL:READTABLE as a superclass (Eclector patch).

(in-package #:eclector.reader)

(defclass kiln-client () ())

(defmethod find-character ((client kiln-client) (designator string))
  (cl:name-char designator))

;;; Bound by the CL functions below, not set globally: Eclector's other
;;; entry points choose their client with (OR *CLIENT* default), as the
;;; CST reader does.
(defvar *kiln-client* (make-instance 'kiln-client))

(defmacro with-kiln-client (&body body)
  `(let ((eclector.base:*client* (or eclector.base:*client* *kiln-client*)))
     ,@body))

(defmethod state-value ((client kiln-client) (aspect (eql 'cl:*readtable*)))
  cl:*readtable*)

(defmethod (setf state-value) (new-value (client kiln-client) (aspect (eql 'cl:*readtable*)))
  (setf cl:*readtable* new-value))

(defmethod call-with-state-value ((client kiln-client) thunk (aspect (eql 'cl:*readtable*)) value)
  (let ((cl:*readtable* value))
    (funcall thunk)))

(setf cl:*readtable* eclector.readtable:*readtable*)
(setf kiln.kernel::*standard-readtable* *standard-readtable*)

;;; Reading

(defun cl:read (&optional (input-stream *standard-input*) (eof-error-p t) eof-value recursive-p)
  (with-kiln-client (read input-stream eof-error-p eof-value recursive-p)))

(defun cl:read-preserving-whitespace
    (&optional (input-stream *standard-input*) (eof-error-p t) eof-value recursive-p)
  (with-kiln-client
    (read-preserving-whitespace input-stream eof-error-p eof-value recursive-p)))

(defun cl:read-from-string (string &optional (eof-error-p t) eof-value
                            &key (start 0) end preserve-whitespace)
  (with-kiln-client
    (read-from-string string eof-error-p eof-value
                      :start start :end end :preserve-whitespace preserve-whitespace)))

(defun cl:read-delimited-list (char &optional (input-stream *standard-input*) recursive-p)
  (with-kiln-client (read-delimited-list char input-stream recursive-p)))

;;; Readtables

(defun readtable-designator (designator)
  (if (null designator) *standard-readtable* designator))

(defun cl:readtablep (object)
  (eclector.readtable:readtablep object))

(defun cl:copy-readtable (&optional (from-readtable cl:*readtable*) to-readtable)
  (let ((from (readtable-designator from-readtable)))
    (if to-readtable
        (eclector.readtable:copy-readtable-into from to-readtable)
        (eclector.readtable:copy-readtable from))))

(defun cl:readtable-case (readtable)
  (eclector.readtable:readtable-case readtable))

(defun (setf cl:readtable-case) (mode readtable)
  (setf (eclector.readtable:readtable-case readtable) mode))

(defun cl:make-dispatch-macro-character (char &optional non-terminating-p
                                                (readtable cl:*readtable*))
  (eclector.readtable:make-dispatch-macro-character readtable char non-terminating-p)
  t)

;;; Eclector keeps the standard reader macros as symbols; CL returns
;;; functions.
(defun function-of (designator)
  (if (and designator (symbolp designator)) (fdefinition designator) designator))

(defun cl:get-macro-character (char &optional (readtable cl:*readtable*))
  (multiple-value-bind (function non-terminating-p)
      (eclector.readtable:get-macro-character (readtable-designator readtable) char)
    (values (function-of function) non-terminating-p)))

(defun cl:set-macro-character (char function &optional non-terminating-p
                                                 (readtable cl:*readtable*))
  (eclector.readtable:set-macro-character readtable char function non-terminating-p)
  t)

(defun cl:get-dispatch-macro-character (disp-char sub-char &optional (readtable cl:*readtable*))
  (function-of (eclector.readtable:get-dispatch-macro-character
                (readtable-designator readtable) disp-char sub-char)))

(defun cl:set-dispatch-macro-character (disp-char sub-char function
                                        &optional (readtable cl:*readtable*))
  (eclector.readtable:set-dispatch-macro-character readtable disp-char sub-char function)
  t)

(defun cl:set-syntax-from-char (to-char from-char &optional (to-readtable cl:*readtable*)
                                                    from-readtable)
  (setf (eclector.readtable:syntax-from-char to-char to-readtable
                                             (readtable-designator from-readtable))
        from-char)
  t)
