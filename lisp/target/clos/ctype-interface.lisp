;;;; The standard functions on types, from ctype (docs/10 §13).

(in-package #:ctype)

(defvar *kiln-client* (make-instance 'kiln-client))

;;; Parsed specifiers and SUBTYPEP answers are cached (EQUAL hash tables)
;;; until a type or class is defined (kiln.kernel::invalidate-type-caches).
(defvar *ctype-cache* (make-hash-table :test 'equal))
(defvar *subtypep-cache* (make-hash-table :test 'equal))

(defun check-type-caches ()
  (unless kiln.kernel::*type-caches-valid*
    (clrhash *ctype-cache*)
    (clrhash *subtypep-cache*)
    (setf kiln.kernel::*type-caches-valid* t)))

(defun cached-ctype (specifier environment)
  (if environment
      (specifier-ctype *kiln-client* specifier environment)
      (progn
        (check-type-caches)
        (multiple-value-bind (ctype presentp) (gethash specifier *ctype-cache*)
          (if presentp
              ctype
              (setf (gethash specifier *ctype-cache*)
                    (specifier-ctype *kiln-client* specifier nil)))))))

(defun cl:subtypep (type1 type2 &optional environment)
  (if environment
      (subctypep *kiln-client*
                 (specifier-ctype *kiln-client* type1 environment)
                 (specifier-ctype *kiln-client* type2 environment))
      (let ((key (cons type1 type2)))
        (check-type-caches)
        (multiple-value-bind (answer presentp) (gethash key *subtypep-cache*)
          (if presentp
              (values (car answer) (cdr answer))
              (multiple-value-bind (subtypep validp)
                  (subctypep *kiln-client* (cached-ctype type1 nil) (cached-ctype type2 nil))
                (setf (gethash key *subtypep-cache*) (cons subtypep validp))
                (values subtypep validp)))))))

(defun cl:upgraded-complex-part-type (specifier &optional environment)
  (upgraded-complex-part-type *kiln-client* specifier environment))

;;; Compound specifiers the kernel's TYPEP does not know.
(setf kiln.kernel::*ctype-typep*
      (lambda (object type)
        (ctypep *kiln-client* object (cached-ctype type nil))))
