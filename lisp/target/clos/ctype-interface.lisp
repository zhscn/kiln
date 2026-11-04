;;;; The standard functions on types, from ctype (docs/10 §13).

(in-package #:ctype)

(defvar *kiln-client* (make-instance 'kiln-client))

(defun cl:subtypep (type1 type2 &optional environment)
  (subctypep *kiln-client*
             (specifier-ctype *kiln-client* type1 environment)
             (specifier-ctype *kiln-client* type2 environment)))

(defun cl:upgraded-complex-part-type (specifier &optional environment)
  (upgraded-complex-part-type *kiln-client* specifier environment))

;;; Compound specifiers the kernel's TYPEP does not know.
(setf kiln.kernel::*ctype-typep*
      (lambda (object type)
        (ctypep *kiln-client* object (specifier-ctype *kiln-client* type))))
