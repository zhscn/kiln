;;;; Hash tables: Salmagundi's bucket hash tables with kiln's client and
;;;; the CL interface (what Salmagundi's Trinsic-generated interface does,
;;;; written out).

(in-package #:salmagundi)

(defclass kiln-client (salmagundi/bucket:bucket-client)
  ())

;;; The hash state is a fixnum mixed one 62-bit chunk of each integer at a
;;; time with a wrapping FNV-1a step (%PRIMOP :HASH-MIX), so that hashing
;;; does not cons bignums.
(defun mix-integer (hash value)
  (loop (setf hash (kiln.sys:%primop :hash-mix hash (logand value #x3fffffffffffffff)))
        (setf value (ash value -62))
        (when (or (eql value 0) (eql value -1))
          (return hash))))

(defmethod make-hash ((client kiln-client))
  (let ((hash #x0bf29ce484222325))
    (values (lambda (value)
              (setf hash (mix-integer hash value))
              nil)
            (lambda ()
              (logand hash #x3fffffffffffffff)))))

(defvar *client* (make-instance 'kiln-client))

(defmacro define-hash-function (name accumulating-function)
  `(defun ,name (object)
     (multiple-value-bind (accumulate finalize) (make-hash *client*)
       (,accumulating-function accumulate object)
       (funcall finalize))))

(define-hash-function slow-eql-hash eql-hash)
(define-hash-function slow-equal-hash equal-hash)

;;; The hash functions of EQ, EQL and EQUAL tables compute the common
;;; cases directly (Salmagundi's accumulating functions cons closures and
;;; dispatch on the type at each step); the others go to Salmagundi's.
(defconstant +hash-mask+ #x3fffffffffffffff)

(defun kiln-eq-hash (object)
  (logand (kiln.sys:%primop :identity-hash object) +hash-mask+))

(defun kiln-eql-hash (object)
  (cond ((kiln.sys:%primop :fixnump object) (logand object +hash-mask+))
        ((characterp object) (char-code object))
        ((numberp object) (slow-eql-hash object))
        (t (kiln-eq-hash object))))

(defun equal-hash-1 (object depth)
  (cond ((consp object)
         (if (> depth 8)
             1
             (logand (kiln.sys:%primop :hash-mix
                                       (equal-hash-1 (car object) (+ depth 1))
                                       (equal-hash-1 (cdr object) (+ depth 1)))
                     +hash-mask+)))
        ((stringp object)
         (let ((hash (length object)))
           (dotimes (i (min (length object) 64) (logand hash +hash-mask+))
             (setf hash (kiln.sys:%primop :hash-mix hash (char-code (char object i)))))))
        ((or (symbolp object) (numberp object) (characterp object))
         (kiln-eql-hash object))
        ;; Compared by contents: bit vectors and pathnames.
        ((or (bit-vector-p object) (typep object 'pathname))
         (slow-equal-hash object))
        (t (kiln-eq-hash object))))

(defun kiln-equal-hash (object)
  (equal-hash-1 object 0))
(define-hash-function kiln-equalp-hash equalp-hash)
(define-hash-function cl:sxhash sxhash)

(defmethod default-hash-function ((client kiln-client) (name (eql 'eq))) 'kiln-eq-hash)
(defmethod default-hash-function ((client kiln-client) (name (eql 'eql))) 'kiln-eql-hash)
(defmethod default-hash-function ((client kiln-client) (name (eql 'equal))) 'kiln-equal-hash)
(defmethod default-hash-function ((client kiln-client) (name (eql 'equalp))) 'kiln-equalp-hash)

;;; GETHASH, (SETF GETHASH) and REMHASH go straight to the bucket table's
;;; functions; they are Salmagundi's generic functions otherwise
;;; (vendor/README.md).
(defun cl:gethash (key hash-table &optional default)
  (if (salmagundi/bucket::bucket-hash-table-p hash-table)
      (salmagundi/bucket::bucket-gethash key hash-table default)
      (gethash key hash-table default)))

(defun (setf cl:gethash) (value key hash-table &optional default)
  (if (salmagundi/bucket::bucket-hash-table-p hash-table)
      (salmagundi/bucket::bucket-set value key hash-table)
      (setf (gethash key hash-table default) value)))

(defun cl:remhash (key hash-table)
  (if (salmagundi/bucket::bucket-hash-table-p hash-table)
      (salmagundi/bucket::bucket-remhash key hash-table)
      (remhash key hash-table)))

(defun cl:make-hash-table (&rest initargs
                           &key test size rehash-size rehash-threshold hash-function
                           &allow-other-keys)
  (declare (ignore test size rehash-size rehash-threshold hash-function))
  (apply #'make-hash-table *client* initargs))

(defmacro cl:with-hash-table-iterator ((name hash-table) &body body)
  (let ((iterator (gensym "ITERATOR")))
    `(let ((,iterator (make-hash-table-iterator ,hash-table)))
       (macrolet ((,name () '(funcall ,iterator)))
         ,@body))))
