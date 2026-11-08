;;;; The standard functions on types, from ctype.

(in-package #:ctype)

(defvar *kiln-client* (make-instance 'kiln-client))

;;; Parsed specifiers and SUBTYPEP answers are cached (EQUAL hash tables)
;;; for one version of the type assumption: a new type, a new class or a
;;; changed class definition empties them (kiln.kernel::invalidate-type-caches
;;; clears the TYPEP tables, and this version tells when).
(defvar *ctype-cache* (make-hash-table :test 'equal))
(defvar *subtypep-cache* (make-hash-table :test 'equal))
(defvar *ctype-cache-version* -1)

(defun check-type-caches ()
  (let ((version (kiln.kernel::type-assumption-version)))
    (unless (eql version *ctype-cache-version*)
      (clrhash *ctype-cache*)
      (clrhash *subtypep-cache*)
      (setf *ctype-cache-version* version))))

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

(defun subtypep-uncached (type1 type2)
  (subctypep *kiln-client* (cached-ctype type1 nil) (cached-ctype type2 nil)))

(defun cl:subtypep (type1 type2 &optional environment)
  (if (and (null environment) (symbolp type1) (symbolp type2))
      ;; Two symbols: an alist on TYPE1's plist, valid for one epoch of
      ;; the type definitions.
      (let ((entry (get type1 'subtypep-cache))
            (version (kiln.kernel::type-assumption-version)))
        (unless (and entry (eql (car entry) version))
          (setf entry (cons version '()))
          (setf (get type1 'subtypep-cache) entry))
        (let ((hit (assoc type2 (cdr entry) :test #'eq)))
          (if hit
              (values (cadr hit) (cddr hit))
              (multiple-value-bind (subtypep validp) (subtypep-uncached type1 type2)
                (push (list* type2 subtypep validp) (cdr entry))
                (values subtypep validp)))))
      (subtypep-general type1 type2 environment)))

(defun subtypep-general (type1 type2 environment)
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
