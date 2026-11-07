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

(declaim (inline core))
(defun core (hash-table)
  (kiln.sys:%primop :standard-instance-access hash-table *core-location*))

(defun test-code (test)
  (cond ((or (eq test 'eq) (eq test #'eq)) 0)
        ((or (eq test 'eql) (eq test #'eql)) 1)
        ((or (eq test 'equal) (eq test #'equal)) 2)
        (t 3)))

(defun power-of-two-at-least (n)
  (let ((p 8)) (loop while (< p n) do (setf p (* p 2))) p))

(defmethod initialize-instance :after ((hash-table bucket-hash-table) &key)
  (let* ((capacity (max 4 (slot-value hash-table 'size)))
         (core (make-array +core-length+))
         (test (salmagundi:hash-table-test hash-table))
         (hash (salmagundi:hash-table-hash-function hash-table)))
    (setf (svref core +index+) (make-array (power-of-two-at-least (* 2 capacity))
                                           :initial-element 0)
          (svref core +keys+) (make-array capacity :initial-element +free-key+)
          (svref core +values+) (make-array capacity :initial-element nil)
          (svref core +hashes+) (make-array capacity :initial-element 0)
          (svref core +count+) 0
          (svref core +test-code+) (test-code test)
          (svref core +test+) (if (functionp test) test (fdefinition test))
          (svref core +hash+) (if (functionp hash) hash (fdefinition hash))
          (svref core +fill+) 0
          (svref core +free+) '()
          (svref core +removed+) 0)
    (setf (hash-table-core hash-table) core)
    (unless *core-location*
      (setf *core-location*
            (clostrophilia:slot-definition-location
             (find 'core (clostrophilia:class-slots (class-of hash-table))
                   :key #'clostrophilia:slot-definition-name))))))

(defmethod salmagundi:make-hash-table ((client bucket-client) &rest initargs
                                       &key test size rehash-size rehash-threshold)
  (declare (ignore test size rehash-size rehash-threshold))
  (apply #'make-instance 'bucket-hash-table initargs))

(defmethod salmagundi:hash-table-size ((hash-table bucket-hash-table))
  (length (svref (core hash-table) +keys+)))

(defmethod salmagundi:hash-table-count ((hash-table bucket-hash-table))
  (svref (core hash-table) +count+))

(defmethod salmagundi:make-hash-table-iterator ((hash-table bucket-hash-table))
  (let ((position 0)
        (core (core hash-table)))
    (lambda ()
      (loop
        (when (>= position (svref core +fill+))
          (return nil))
        (let ((key (svref (svref core +keys+) position)))
          (setf position (+ position 1))
          (unless (eq key +free-key+)
            (return (values t key (svref (svref core +values+) (- position 1))))))))))

(declaim (inline key-hash))
(defun key-hash (core key)
  (let ((hash (funcall (svref core +hash+) key)))
    ;; The standard hash functions return non-negative fixnums; a user's
    ;; may return any integer.
    (if (kiln.sys:%primop :fixnump hash)
        hash
        (ldb (byte 61 0) hash))))

(defmacro do-probe ((core hash index-var element-var) &body body)
  "Runs BODY for each index element of the probe sequence of HASH, with
INDEX-VAR its place in the index; BODY returns to leave."
  (let ((index (gensym)) (mask (gensym)))
    `(let* ((,index (svref ,core +index+))
            (,mask (- (length ,index) 1))
            (,index-var (kiln.sys:%primop :fixnum-logand ,hash ,mask)))
       (loop
         (let ((,element-var (svref ,index ,index-var)))
           ,@body)
         (setf ,index-var (kiln.sys:%primop :fixnum-logand (+ ,index-var 1) ,mask))))))

(defun find-place (core key hash)
  "The place of KEY's entry (its hash HASH), and its index in the index
vector; or NIL."
  (let ((keys (svref core +keys+))
        (hashes (svref core +hashes+))
        (code (svref core +test-code+)))
    (macrolet ((probe (same)
                 `(do-probe (core hash i element)
                    (cond ((eql element 0) (return (values nil nil)))
                          ((eql element -1))
                          (t (let ((place (- element 1)))
                               (when (and (eql (svref hashes place) hash)
                                          ,same)
                                 (return (values place i)))))))))
      (case code
        (0 (probe (eq key (svref keys place))))
        (1 (probe (eql key (svref keys place))))
        (2 (probe (equal key (svref keys place))))
        (t (let ((test (svref core +test+)))
             (probe (funcall test key (svref keys place)))))))))

(defun rebuild-index (core length)
  "A new index of LENGTH elements for the entries."
  (let* ((index (make-array length :initial-element 0))
         (mask (- length 1))
         (keys (svref core +keys+))
         (hashes (svref core +hashes+)))
    (dotimes (place (svref core +fill+))
      (unless (eq (svref keys place) +free-key+)
        (let ((i (kiln.sys:%primop :fixnum-logand (svref hashes place) mask)))
          (loop until (eql (svref index i) 0)
                do (setf i (kiln.sys:%primop :fixnum-logand (+ i 1) mask)))
          (setf (svref index i) (+ place 1)))))
    (setf (svref core +index+) index
          (svref core +removed+) 0)))

(defun new-place (core)
  "A place for a new entry: the last freed, else the next unused one (the
entry vectors double when full)."
  (if (svref core +free+)
      (pop (svref core +free+))
      (let ((place (svref core +fill+))
            (keys (svref core +keys+)))
        (when (= place (length keys))
          (let* ((capacity (* 2 (length keys)))
                 (new-keys (make-array capacity :initial-element +free-key+))
                 (new-values (make-array capacity :initial-element nil))
                 (new-hashes (make-array capacity :initial-element 0)))
            (replace new-keys keys)
            (replace new-values (svref core +values+))
            (replace new-hashes (svref core +hashes+))
            (setf (svref core +keys+) new-keys
                  (svref core +values+) new-values
                  (svref core +hashes+) new-hashes)))
        (setf (svref core +fill+) (+ place 1))
        place)))

(defun bucket-set (value key hash-table)
  (let* ((core (core hash-table))
         (hash (key-hash core key)))
    (let ((place (find-place core key hash)))
      (if place
          (setf (svref (svref core +values+) place) value)
          (let ((place (new-place core)))
            (setf (svref (svref core +keys+) place) key
                  (svref (svref core +values+) place) value
                  (svref (svref core +hashes+) place) hash
                  (svref core +count+) (+ (svref core +count+) 1))
            ;; At most half of the index used (entries and removed ones);
            ;; else a new index, twice as long if the entries need it.
            (let ((length (length (svref core +index+))))
              (if (> (* 2 (+ (svref core +count+) (svref core +removed+))) length)
                  (rebuild-index core (if (> (* 4 (svref core +count+)) length)
                                          (* 2 length)
                                          length))
                  (do-probe (core hash i element)
                    (when (or (eql element 0) (eql element -1))
                      (when (eql element -1)
                        (setf (svref core +removed+) (- (svref core +removed+) 1)))
                      (setf (svref (svref core +index+) i) (+ place 1))
                      (return nil))))))))
    value))

(defun bucket-gethash (key hash-table default)
  (let* ((core (core hash-table))
         (place (find-place core key (key-hash core key))))
    (if place
        (values (svref (svref core +values+) place) t)
        (values default nil))))

(defun bucket-remhash (key hash-table)
  (let ((core (core hash-table)))
    (multiple-value-bind (place i) (find-place core key (key-hash core key))
      (when place
        (setf (svref (svref core +index+) i) -1
              (svref (svref core +keys+) place) +free-key+
              (svref (svref core +values+) place) nil
              (svref core +count+) (- (svref core +count+) 1)
              (svref core +removed+) (+ (svref core +removed+) 1))
        (push place (svref core +free+)))
      (not (null place)))))

(defvar *bucket-hash-table-class* (find-class 'bucket-hash-table))

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
    (fill (svref core +index+) 0)
    (fill (svref core +keys+) +free-key+)
    (fill (svref core +values+) nil)
    (setf (svref core +count+) 0
          (svref core +fill+) 0
          (svref core +free+) '()
          (svref core +removed+) 0))
  hash-table)

(defmethod salmagundi:maphash (function (hash-table bucket-hash-table))
  ;; The function may set or remove the current entry (CLHS 3.6).
  (let ((core (core hash-table)))
    (dotimes (place (svref core +fill+))
      (let ((key (svref (svref core +keys+) place)))
        (unless (eq key +free-key+)
          (funcall function key (svref (svref core +values+) place)))))))
