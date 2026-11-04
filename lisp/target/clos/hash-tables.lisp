;;;; Hash tables: Salmagundi's bucket hash tables with kiln's client and
;;;; the CL interface (what Salmagundi's Trinsic-generated interface does,
;;;; written out; docs/10 §11).

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

(define-hash-function kiln-eq-hash eq-hash)
(define-hash-function kiln-eql-hash eql-hash)
(define-hash-function kiln-equal-hash equal-hash)
(define-hash-function kiln-equalp-hash equalp-hash)
(define-hash-function cl:sxhash sxhash)

(defmethod default-hash-function ((client kiln-client) (name (eql 'eq))) 'kiln-eq-hash)
(defmethod default-hash-function ((client kiln-client) (name (eql 'eql))) 'kiln-eql-hash)
(defmethod default-hash-function ((client kiln-client) (name (eql 'equal))) 'kiln-equal-hash)
(defmethod default-hash-function ((client kiln-client) (name (eql 'equalp))) 'kiln-equalp-hash)

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
