;;;; The standard functions on types, from ctype.

(in-package #:ctype)

(defvar *kiln-client* (make-instance 'kiln-client))

;;; Parsed specifiers and SUBTYPEP answers use EQUAL hash tables. Syntax
;;; is copied into keys, and literal operands use EQL identity tokens. Entries
;;; remain valid for one version of the type assumption: a new type, a new class or a
;;; changed class definition empties them (kiln.kernel::invalidate-type-caches
;;; clears the TYPEP tables, and this version tells when).
(defvar *ctype-cache* (make-hash-table :test 'equal))
(defvar *subtypep-cache* (make-hash-table :test 'equal))
(defvar *ctype-cache-version* -1)
(defvar *literal-type-tokens* (make-hash-table :test 'eql))

(defun literal-type-token (object)
  (or (gethash object *literal-type-tokens*)
      (setf (gethash object *literal-type-tokens*) (make-symbol "TYPE-LITERAL"))))

(defun type-cache-key (specifier)
  (cond ((atom specifier) (values specifier t))
        ((member (car specifier) '(eql member))
         (values (cons (car specifier) (mapcar #'literal-type-token (cdr specifier))) t))
        ((and (symbolp (car specifier))
              (get (car specifier) 'kiln.kernel::type-expander))
         ;; An expander may inspect the identity or mutable contents of its arguments.
         (values nil nil))
        (t
         (multiple-value-bind (head headp) (type-cache-key (car specifier))
           (multiple-value-bind (tail tailp) (type-cache-key (cdr specifier))
             (values (cons head tail) (and headp tailp)))))))

(defun check-type-caches ()
  (let ((version (kiln.kernel::type-assumption-version)))
    (unless (eql version *ctype-cache-version*)
      (clrhash *ctype-cache*)
      (clrhash *subtypep-cache*)
      (clrhash *literal-type-tokens*)
      (setf *ctype-cache-version* version))))

(defun cached-ctype (specifier environment)
  (if environment
      (specifier-ctype *kiln-client* specifier environment)
      (progn
        (check-type-caches)
        (multiple-value-bind (key cachep) (type-cache-key specifier)
          (if (not cachep)
              (specifier-ctype *kiln-client* specifier nil)
              (multiple-value-bind (ctype presentp) (gethash key *ctype-cache*)
                (if presentp ctype
                    (setf (gethash key *ctype-cache*)
                          (specifier-ctype *kiln-client* specifier nil)))))))))


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
      (progn
        (check-type-caches)
        (multiple-value-bind (key1 cache1p) (type-cache-key type1)
          (multiple-value-bind (key2 cache2p) (type-cache-key type2)
            (if (not (and cache1p cache2p))
                (subtypep-uncached type1 type2)
                (let ((key (cons key1 key2)))
                  (multiple-value-bind (answer presentp) (gethash key *subtypep-cache*)
                    (if presentp
                        (values (car answer) (cdr answer))
                        (multiple-value-bind (subtypep validp) (subtypep-uncached type1 type2)
                          (setf (gethash key *subtypep-cache*) (cons subtypep validp))
                          (values subtypep validp)))))))))))


(defun cl:upgraded-complex-part-type (specifier &optional environment)
  (upgraded-complex-part-type *kiln-client* specifier environment))

;;; Compound specifiers the kernel's TYPEP does not know.
(setf kiln.kernel::*ctype-typep*
      (lambda (object type)
        (ctypep *kiln-client* object (cached-ctype type nil))))
