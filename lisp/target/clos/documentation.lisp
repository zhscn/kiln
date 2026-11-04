;;;; DOCUMENTATION and (SETF DOCUMENTATION) become generic functions
;;;; (CLHS: standard generic functions), so that libraries can add methods
;;;; (Maclina does, for its bytecode functions). The kernel's functions,
;;;; which keep documentation strings on the plist of the name, are the
;;;; default methods.

(in-package #:kiln.kernel)

(defvar *early-documentation* #'documentation)
(defvar *early-setf-documentation* #'(setf documentation))

(fmakunbound 'documentation)
(fmakunbound '(setf documentation))

(defgeneric documentation (x doc-type))
(defgeneric (setf documentation) (new-value x doc-type))

(defmethod documentation (x doc-type)
  (funcall *early-documentation* x doc-type))

(defmethod (setf documentation) (new-value x doc-type)
  (funcall *early-setf-documentation* new-value x doc-type))
