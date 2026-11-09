;;; kiln: rewritten for speed and for SBCL's iteration order.
;;;
;;; Order: the entries are kept in the order SBCL's hash tables iterate in
;;; too: insertion order, a removed entry's place reused by the next
;;; insertion (the last freed first). kiln's compiler on kiln must make the
;;; KIR SBCL makes, and macro expanders iterate over hash tables (Khazern's
;;; destructuring temporaries).
;;;
;;; Representation (open addressing, as CPython's dict): the entries are in
;;; three vectors in that order, KEYS, VALUES and HASHES (the key's hash, a
;;; fixnum); a removed entry's key is +FREE-KEY+. An INDEX vector, whose
;;; length is a power of two, maps a hash to a place by linear probing:
;;; each element is 0 (empty), -1 (a removed entry: probing goes on) or
;;; the entry's place + 1. Nothing is allocated per entry, and a lookup
;;; compares hashes before keys.
;;;
;;; Speed: what GETHASH needs is in one simple vector, the table's CORE,
;;; read from the instance at a fixed location (no accessor calls); EQ,
;;; EQL and EQUAL are compared inline.

(cl:in-package #:salmagundi/bucket)

(defclass bucket-client (salmagundi:standard-client) ())

(defclass bucket-hash-table (salmagundi:hash-table)
  ((size :initarg :size :initform 16)
   (core :accessor hash-table-core)))

;;; The core's elements.
(defconstant +index+ 0)                 ; simple vector, a power of two long
(defconstant +keys+ 1)
(defconstant +values+ 2)
(defconstant +hashes+ 3)
(defconstant +count+ 4)
(defconstant +test-code+ 5)             ; 0 EQ, 1 EQL, 2 EQUAL, 3 other
(defconstant +test+ 6)                  ; the test function
(defconstant +hash+ 7)                  ; the hash function
(defconstant +fill+ 8)                  ; places of KEYS used so far
(defconstant +free+ 9)                  ; freed places, last freed first
(defconstant +removed+ 10)              ; -1 elements of INDEX
(defconstant +core-length+ 11)

(defvar +free-key+ (list '+free-key+))

(defvar *core-location* nil)
(defvar *test-location* nil)
(defvar *rehash-size-location* nil)
(defvar *rehash-threshold-location* nil)
(defvar *hash-function-location* nil)
(defvar *size-location* nil)

(declaim (inline core-ref (setf core-ref) core))
(defun core-ref (v i)
  (kiln.sys:%primop :svref-unchecked v i))

(defun (setf core-ref) (x v i)
  (kiln.sys:%primop :set-svref-unchecked v i x))

(defun core (hash-table)
  (kiln.sys:%primop :standard-instance-access hash-table *core-location*))

(defun test-code (test hash)
  (cond ((and (or (eq test 'eq) (eq test #'eq))
              (eq hash 'salmagundi::kiln-eq-hash))
         0)
        ((and (or (eq test 'eql) (eq test #'eql))
              (eq hash 'salmagundi::kiln-eql-hash))
         1)
        ((or (eq test 'equal) (eq test #'equal)) 2)
        (t 3)))

(defun power-of-two-at-least (n)
  (let ((p 8)) (loop while (< p n) do (setf p (* p 2))) p))

(defun make-core (capacity code test-fn hash-fn)
  (let ((core (kiln.kernel::make-simple-vector +core-length+ nil)))
    (setf (core-ref core +index+) (kiln.kernel::make-simple-vector
                                   (power-of-two-at-least (* 2 capacity)) 0)
          (core-ref core +keys+) (kiln.kernel::make-simple-vector capacity +free-key+)
          (core-ref core +values+) (kiln.kernel::make-simple-vector capacity nil)
          (core-ref core +hashes+) (kiln.kernel::make-simple-vector capacity 0)
          (core-ref core +count+) 0
          (core-ref core +test-code+) code
          (core-ref core +test+) test-fn
          (core-ref core +hash+) hash-fn
          (core-ref core +fill+) 0
          (core-ref core +free+) '()
          (core-ref core +removed+) 0)
    core))

(defmethod initialize-instance :after ((hash-table bucket-hash-table) &key)
  (let* ((capacity (max 4 (slot-value hash-table 'size)))
         (test (salmagundi:hash-table-test hash-table))
         (hash (salmagundi:hash-table-hash-function hash-table))
         (core (make-core capacity (test-code test hash)
                          (if (functionp test) test (fdefinition test))
                          (if (functionp hash) hash (fdefinition hash)))))
    (setf (hash-table-core hash-table) core)
    (unless *core-location*
      (let ((slots (clostrophilia:class-slots (class-of hash-table))))
        (flet ((loc (name)
                 (clostrophilia:slot-definition-location
                  (find name slots :key #'clostrophilia:slot-definition-name))))
          (setf *test-location* (loc 'salmagundi::%test)
                *rehash-size-location* (loc 'salmagundi::%rehash-size)
                *rehash-threshold-location* (loc 'salmagundi::%rehash-threshold)
                *hash-function-location* (loc 'salmagundi::%hash-function)
                *size-location* (loc 'size)
                *core-location* (loc 'core)))))))

(defmethod salmagundi:make-hash-table ((client bucket-client) &rest initargs
                                       &key test size rehash-size rehash-threshold)
  (declare (ignore test size rehash-size rehash-threshold))
  (apply #'make-instance 'bucket-hash-table initargs))

(defmethod salmagundi:hash-table-size ((hash-table bucket-hash-table))
  (kiln.sys:%primop :length (core-ref (core hash-table) +keys+)))

(defmethod salmagundi:hash-table-count ((hash-table bucket-hash-table))
  (core-ref (core hash-table) +count+))

(defmethod salmagundi:make-hash-table-iterator ((hash-table bucket-hash-table))
  (let ((position 0)
        (core (core hash-table)))
    (lambda ()
      (loop
        (when (>= position (core-ref core +fill+))
          (return nil))
        (let ((key (core-ref (core-ref core +keys+) position)))
          (setf position (kiln.sys:%primop :fixnum+ position 1))
          (unless (eq key +free-key+)
            (return (values t key (core-ref (core-ref core +values+)
                                            (kiln.sys:%primop :fixnum+ position -1))))))))))

(declaim (inline key-hash))
(defun key-hash (core key)
  (case (core-ref core +test-code+)
    (0 (kiln.sys:%primop :identity-hash key))
    (1 (cond ((kiln.sys:%primop :fixnump key)
              (kiln.sys:%primop :fixnum-logand key #x3fffffffffffffff))
             ((characterp key) (kiln.sys:%primop :char-code key))
             ((not (numberp key)) (kiln.sys:%primop :identity-hash key))
             (t (funcall (core-ref core +hash+) key))))
    (t (let ((hash (funcall (core-ref core +hash+) key)))
         (if (kiln.sys:%primop :fixnump hash)
             hash
             (ldb (byte 61 0) hash))))))

(defmacro do-probe ((core hash index-var element-var) &body body)
  "Runs BODY for each index element of the probe sequence of HASH, with
INDEX-VAR its place in the index; BODY returns to leave."
  (let ((index (gensym)) (mask (gensym)))
    `(let* ((,index (core-ref ,core +index+))
            (,mask (kiln.sys:%primop :fixnum+ (kiln.sys:%primop :length ,index) -1))
            (,index-var (kiln.sys:%primop :fixnum-logand ,hash ,mask)))
       (loop
         (let ((,element-var (core-ref ,index ,index-var)))
           ,@body)
         (setf ,index-var
               (kiln.sys:%primop :fixnum-logand
                                 (kiln.sys:%primop :fixnum+ ,index-var 1) ,mask))))))

(defun find-place (core key hash)
  "The place of KEY's entry (its hash HASH), and its index in the index
vector; or NIL and the first free index."
  (let ((keys (core-ref core +keys+))
        (hashes (core-ref core +hashes+))
        (code (core-ref core +test-code+))
        (free nil))
    (macrolet ((probe (same)
                 `(do-probe (core hash i element)
                    (cond ((eql element 0) (return (values nil (or free i))))
                          ((eql element -1) (unless free (setf free i)))
                          (t (let ((place (kiln.sys:%primop :fixnum+ element -1)))
                               (when (and (eql (core-ref hashes place) hash)
                                          ,same)
                                 (return (values place i)))))))))
      (case code
        (0 (probe (eq key (core-ref keys place))))
        (1 (probe (eql key (core-ref keys place))))
        (2 (probe (equal key (core-ref keys place))))
        (t (let ((test (core-ref core +test+)))
             (probe (funcall test key (core-ref keys place)))))))))

(defun rebuild-index (core length)
  "A new index of LENGTH elements for the entries."
  (let* ((index (kiln.kernel::make-simple-vector length 0))
         (mask (kiln.sys:%primop :fixnum+ length -1))
         (keys (core-ref core +keys+))
         (hashes (core-ref core +hashes+)))
    (dotimes (place (core-ref core +fill+))
      (unless (eq (core-ref keys place) +free-key+)
        (let ((i (kiln.sys:%primop :fixnum-logand (core-ref hashes place) mask)))
          (loop until (eql (core-ref index i) 0)
                do (setf i (kiln.sys:%primop :fixnum-logand
                                             (kiln.sys:%primop :fixnum+ i 1) mask)))
          (setf (core-ref index i) (kiln.sys:%primop :fixnum+ place 1)))))
    (setf (core-ref core +index+) index
          (core-ref core +removed+) 0)))

(defun new-place (core)
  "A place for a new entry: the last freed, else the next unused one (the
entry vectors double when full)."
  (if (core-ref core +free+)
      (pop (core-ref core +free+))
      (let* ((place (core-ref core +fill+))
             (keys (core-ref core +keys+))
             (len (kiln.sys:%primop :length keys)))
        (when (= place len)
          (let* ((capacity (* 2 len))
                 (values (core-ref core +values+))
                 (hashes (core-ref core +hashes+))
                 (new-keys (kiln.kernel::make-simple-vector capacity +free-key+))
                 (new-values (kiln.kernel::make-simple-vector capacity nil))
                 (new-hashes (kiln.kernel::make-simple-vector capacity 0)))
            ;; kiln: the primitive allocation and a plain copy (MAKE-ARRAY
            ;; parses its keywords, REPLACE its own).
            (dotimes (i place)
              (setf (core-ref new-keys i) (core-ref keys i)
                    (core-ref new-values i) (core-ref values i)
                    (core-ref new-hashes i) (core-ref hashes i)))
            (setf (core-ref core +keys+) new-keys
                  (core-ref core +values+) new-values
                  (core-ref core +hashes+) new-hashes)))
        (setf (core-ref core +fill+) (kiln.sys:%primop :fixnum+ place 1))
        place)))

(defun bucket-set (value key hash-table)
  (let* ((core (core hash-table))
         (hash (key-hash core key)))
    (multiple-value-bind (place index-slot) (find-place core key hash)
      (if place
          (setf (core-ref (core-ref core +values+) place) value)
          (let ((place (new-place core))
                (count (kiln.sys:%primop :fixnum+ (core-ref core +count+) 1)))
            (setf (core-ref (core-ref core +keys+) place) key
                  (core-ref (core-ref core +values+) place) value
                  (core-ref (core-ref core +hashes+) place) hash
                  (core-ref core +count+) count)
            ;; At most half of the index used (entries and removed ones);
            ;; else a new index, twice as long if the entries need it.
            (let* ((index (core-ref core +index+))
                   (length (kiln.sys:%primop :length index))
                   (removed (core-ref core +removed+)))
              (if (> (* 2 (kiln.sys:%primop :fixnum+ count removed)) length)
                  (rebuild-index core (if (> (* 4 count) length)
                                          (* 2 length)
                                          length))
                  (progn
                    (when (eql (core-ref index index-slot) -1)
                      (setf (core-ref core +removed+)
                            (kiln.sys:%primop :fixnum+ removed -1)))
                    (setf (core-ref index index-slot)
                          (kiln.sys:%primop :fixnum+ place 1)))))))))
    value)

(defun bucket-gethash (key hash-table default)
  (let* ((core (core hash-table))
         (place (find-place core key (key-hash core key))))
    (if place
        (values (core-ref (core-ref core +values+) place) t)
        (values default nil))))

(defun bucket-remhash (key hash-table)
  (let ((core (core hash-table)))
    (multiple-value-bind (place i) (find-place core key (key-hash core key))
      (when place
        (setf (core-ref (core-ref core +index+) i) -1
              (core-ref (core-ref core +keys+) place) +free-key+
              (core-ref (core-ref core +values+) place) nil
              (core-ref core +count+) (kiln.sys:%primop :fixnum+ (core-ref core +count+) -1)
              (core-ref core +removed+) (kiln.sys:%primop :fixnum+ (core-ref core +removed+) 1))
        (push place (core-ref core +free+)))
      (not (null place)))))

(defvar *bucket-hash-table-class* (find-class 'bucket-hash-table))

(defun make-bucket-hash-table (test size rehash-size rehash-threshold hash code test-fn hash-fn)
  (if *core-location*
      (let* ((class *bucket-hash-table-class*)
             (core (make-core (max 4 size) code test-fn hash-fn))
             (ht (kiln.sys:%primop :allocate-general-instance class 8)))
        (kiln.sys:%primop :set-standard-instance-access ht -2
                          (clostrophilia::%slot class 'clostrophilia::%unique-number))
        (kiln.sys:%primop :set-standard-instance-access ht -1
                          (clostrophilia::%slot class 'clostrophilia::%effective-slots))
        (kiln.sys:%primop :set-standard-instance-access ht *test-location* test)
        (kiln.sys:%primop :set-standard-instance-access ht *rehash-size-location* rehash-size)
        (kiln.sys:%primop :set-standard-instance-access ht *rehash-threshold-location*
                          rehash-threshold)
        (kiln.sys:%primop :set-standard-instance-access ht *hash-function-location* hash)
        (kiln.sys:%primop :set-standard-instance-access ht *size-location* size)
        (kiln.sys:%primop :set-standard-instance-access ht *core-location* core)
        ht)
      (make-instance 'bucket-hash-table
                     :test test :size size :rehash-size rehash-size
                     :rehash-threshold rehash-threshold :hash-function hash)))

(declaim (inline bucket-hash-table-p))
(defun bucket-hash-table-p (object)
  (and (kiln.sys:%primop :standard-instance-p object)
       (eq (kiln.sys:%primop :instance-class object) *bucket-hash-table-class*)))

(defmethod (setf salmagundi:gethash) (value key (hash-table bucket-hash-table) &optional default)
  (declare (ignore default))
  (bucket-set value key hash-table))

(defmethod salmagundi:gethash (key (hash-table bucket-hash-table) &optional default)
  (bucket-gethash key hash-table default))

(defmethod salmagundi:remhash (key (hash-table bucket-hash-table))
  (bucket-remhash key hash-table))

(defmethod salmagundi:clrhash ((hash-table bucket-hash-table))
  (let ((core (core hash-table)))
    (fill (core-ref core +index+) 0)
    (fill (core-ref core +keys+) +free-key+)
    (fill (core-ref core +values+) nil)
    (setf (core-ref core +count+) 0
          (core-ref core +fill+) 0
          (core-ref core +free+) '()
          (core-ref core +removed+) 0))
  hash-table)

(defmethod salmagundi:maphash (function (hash-table bucket-hash-table))
  ;; The function may set or remove the current entry (CLHS 3.6).
  (let ((core (core hash-table)))
    (dotimes (place (core-ref core +fill+))
      (let ((key (core-ref (core-ref core +keys+) place)))
        (unless (eq key +free-key+)
          (funcall function key (core-ref (core-ref core +values+) place)))))))
