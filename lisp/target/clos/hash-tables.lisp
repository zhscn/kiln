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
  (kiln.sys:%primop :identity-hash object))

(defun kiln-eql-hash (object)
  (cond ((kiln.sys:%primop :fixnump object)
         (kiln.sys:%primop :fixnum-logand object +hash-mask+))
        ((characterp object) (kiln.sys:%primop :char-code object))
        ((numberp object) (slow-eql-hash object))
        (t (kiln.sys:%primop :identity-hash object))))

(defun equal-hash-1 (object depth)
  (cond ((consp object)
         (if (kiln.sys:%primop :fixnum-le 9 depth)
             1
             (kiln.sys:%primop :fixnum-logand
                               (kiln.sys:%primop :hash-mix
                                                 (equal-hash-1 (car object)
                                                               (kiln.sys:%primop :fixnum+ depth 1))
                                                 (equal-hash-1 (cdr object)
                                                               (kiln.sys:%primop :fixnum+ depth 1)))
                               +hash-mask+)))
        ((kiln.sys:%primop :stringp object)
         (let* ((len (kiln.sys:%primop :length object))
                (limit (if (kiln.sys:%primop :fixnum-le len 64) len 64))
                (hash len))
           (dotimes (i limit (kiln.sys:%primop :fixnum-logand hash +hash-mask+))
             (setf hash (kiln.sys:%primop :hash-mix hash
                                          (kiln.sys:%primop :char-code
                                                            (kiln.sys:%primop :schar object i)))))))
        ((stringp object)
         (let ((hash (length object)))
           (dotimes (i (min (length object) 64) (kiln.sys:%primop :fixnum-logand hash +hash-mask+))
             (setf hash (kiln.sys:%primop :hash-mix hash (char-code (char object i)))))))
        ((or (symbolp object) (numberp object) (characterp object))
         (kiln-eql-hash object))
        ;; Compared by contents: bit vectors and pathnames.
        ((or (bit-vector-p object) (typep object 'pathname))
         (slow-equal-hash object))
        (t (kiln.sys:%primop :identity-hash object))))

(defun kiln-equal-hash (object)
  (equal-hash-1 object 0))
(define-hash-function kiln-equalp-hash equalp-hash)
(define-hash-function slow-sxhash sxhash)

(defun sxhash-string-1 (string prefix)
  (let* ((length (kiln.sys:%primop :length string))
         (budget *hash-limit*)
         (limit (if (< length budget) length budget))
         (hash (kiln.sys:%primop :hash-mix
                                (kiln.sys:%primop :hash-mix prefix +string-seed+)
                                length)))
    (dotimes (i limit
                (kiln.sys:%primop :fixnum-logand hash +hash-mask+))
      (setf hash (kiln.sys:%primop :hash-mix
                                  hash (kiln.sys:%primop :char-code
                                                        (kiln.sys:%primop :schar string i)))))))

(defun cl:sxhash (object)
  (cond ((kiln.sys:%primop :fixnump object)
         (kiln.sys:%primop :fixnum-logand
                          (kiln.sys:%primop :hash-mix
                                            (kiln.sys:%primop :hash-mix
                                                              #x0bf29ce484222325 +integer-seed+)
                                            (kiln.sys:%primop :fixnum-logand object +hash-mask+))
                          +hash-mask+))
        ((kiln.sys:%primop :stringp object)
         (sxhash-string-1 object (kiln.sys:%primop :hash-mix
                                                 #x0bf29ce484222325 +string-seed+)))
        ((symbolp object)
         (sxhash-string-1 (symbol-name object)
                         (kiln.sys:%primop :hash-mix #x0bf29ce484222325 +symbol-seed+)))
        ((characterp object)
         (kiln.sys:%primop :fixnum-logand
                          (kiln.sys:%primop :hash-mix
                                            (kiln.sys:%primop :hash-mix
                                                              #x0bf29ce484222325 +character-seed+)
                                            (kiln.sys:%primop :char-code object))
                          +hash-mask+))
        (t (slow-sxhash object))))

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
                           &key (test 'eql) (size 16 size-p)
                                (rehash-size 1.5 rehash-size-p)
                                (rehash-threshold 0.8 rehash-threshold-p)
                                (hash-function nil hash-function-p)
                           &allow-other-keys)
  (if (and (not hash-function-p)
           (or (not size-p) (and (kiln.sys:%primop :fixnump size) (<= 0 size)))
           (not rehash-size-p)
           (not rehash-threshold-p))
      (cond ((or (eq test 'eq) (eq test #'eq))
             (salmagundi/bucket::make-bucket-hash-table
              'eq size rehash-size rehash-threshold 'kiln-eq-hash
              0 #'eq #'kiln-eq-hash))
            ((or (eq test 'eql) (eq test #'eql))
             (salmagundi/bucket::make-bucket-hash-table
              'eql size rehash-size rehash-threshold 'kiln-eql-hash
              1 #'eql #'kiln-eql-hash))
            ((or (eq test 'equal) (eq test #'equal))
             (salmagundi/bucket::make-bucket-hash-table
              'equal size rehash-size rehash-threshold 'kiln-equal-hash
              2 #'equal #'kiln-equal-hash))
            ((or (eq test 'equalp) (eq test #'equalp))
             (salmagundi/bucket::make-bucket-hash-table
              'equalp size rehash-size rehash-threshold 'kiln-equalp-hash
              3 #'equalp #'kiln-equalp-hash))
            (t (apply #'make-hash-table *client* initargs)))
      (apply #'make-hash-table *client* initargs)))

(defmacro cl:with-hash-table-iterator ((name hash-table) &body body)
  (let ((iterator (gensym "ITERATOR")))
    `(let ((,iterator (make-hash-table-iterator ,hash-table)))
       (macrolet ((,name () '(funcall ,iterator)))
         ,@body))))

(defun instance-equalp (a b)
  (if (hash-table-p a)
      (and (hash-table-p b)
           (eq (hash-table-test a) (hash-table-test b))
           (= (hash-table-count a) (hash-table-count b))
           (block entries
             (maphash (lambda (key value)
                        (multiple-value-bind (other present) (cl:gethash key b)
                          (unless (and present (equalp value other))
                            (return-from entries nil))))
                      a)
             t))
      (and kiln.kernel::*instance-equal*
           (funcall kiln.kernel::*instance-equal* a b))))

(setf kiln.kernel::*instance-equalp* #'instance-equalp)

(defun unordered-table-hash (table)
  (let ((hash 0)
        (key-hash (case (hash-table-test table)
                    (eq #'kiln-eq-hash)
                    (eql #'kiln-eql-hash)
                    (equal #'kiln-equal-hash)
                    (equalp #'kiln-equalp-hash)
                    (t (lambda (key) (declare (ignore key)) 0)))))
    (maphash (lambda (key value)
               (setf hash (logxor hash
                                 (kiln.sys:%primop :hash-mix
                                                  (funcall key-hash key)
                                                  (kiln-equalp-hash value)))))
             table)
    (logand hash +hash-mask+)))
