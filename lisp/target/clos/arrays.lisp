;;;; Arrays. Simple vectors of T and simple strings are
;;;; native objects (the kernel's). Every other array is an instance of
;;;; one of Regalia's classes: multidimensional arrays, specialized
;;;; vectors, and arrays that are adjustable, have a fill pointer or are
;;;; displaced. Its elements are in a native vector (CONTENTS): a string
;;;; for characters, a simple vector otherwise; a displaced array has none
;;;; and refers to the array it is displaced to.
;;;;
;;;; The kernel's array and sequence functions handle native vectors
;;;; themselves and call *COMPLEX-ARRAY-OP* for the others.

(in-package #:regalia)

(defconstant cl:array-dimension-limit (ash 1 32))
(defconstant cl:array-total-size-limit (ash 1 32))
(defconstant cl:array-rank-limit 64)

;;; Additional storage classes retain the element-type boundaries used by SBCL.
(defclass array-base-char (array-character) ())
(defclass vector-base-char (string array-base-char) ())
(defclass array-nil (array) ())
(defclass vector-nil (vector array-nil) ())
(defclass vector-signed-byte-8 (vector array-signed-byte-8) ())
(defclass array-unsigned-byte-2 (array-unsigned-byte-8) ())
(defclass vector-unsigned-byte-2 (vector-unsigned-byte-8 array-unsigned-byte-2) ())
(defclass array-unsigned-byte-4 (array-unsigned-byte-8) ())
(defclass vector-unsigned-byte-4 (vector-unsigned-byte-8 array-unsigned-byte-4) ())
(defclass array-unsigned-byte-7 (array-unsigned-byte-8) ())
(defclass vector-unsigned-byte-7 (vector-unsigned-byte-8 array-unsigned-byte-7) ())
(defclass array-unsigned-byte-15 (array-unsigned-byte-16) ())
(defclass vector-unsigned-byte-15 (vector-unsigned-byte-16 array-unsigned-byte-15) ())
(defclass array-unsigned-byte-31 (array-unsigned-byte-32) ())
(defclass vector-unsigned-byte-31 (vector-unsigned-byte-32 array-unsigned-byte-31) ())
(defclass array-unsigned-byte-62 (array-unsigned-byte-64) ())
(defclass vector-unsigned-byte-62 (vector-unsigned-byte-64 array-unsigned-byte-62) ())
(defclass array-unsigned-byte-63 (array-unsigned-byte-64) ())
(defclass vector-unsigned-byte-63 (vector-unsigned-byte-64 array-unsigned-byte-63) ())
(defclass array-fixnum (array-signed-byte-64) ())
(defclass vector-fixnum (vector-signed-byte-64 array-fixnum) ())

;;; Element types

(defparameter *element-types*
  '((array-t . t) (array-bit . bit) (array-character . character)
    (array-base-char . base-char) (array-nil . nil) (array-fixnum . fixnum)
    (array-unsigned-byte-2 . (unsigned-byte 2))
    (array-unsigned-byte-4 . (unsigned-byte 4))
    (array-unsigned-byte-7 . (unsigned-byte 7))
    (array-unsigned-byte-15 . (unsigned-byte 15))
    (array-unsigned-byte-31 . (unsigned-byte 31))
    (array-unsigned-byte-62 . (unsigned-byte 62))
    (array-unsigned-byte-63 . (unsigned-byte 63))
    (array-unsigned-byte-8 . (unsigned-byte 8))
    (array-unsigned-byte-16 . (unsigned-byte 16))
    (array-unsigned-byte-32 . (unsigned-byte 32))
    (array-unsigned-byte-64 . (unsigned-byte 64))
    (array-signed-byte-8 . (signed-byte 8))
    (array-signed-byte-16 . (signed-byte 16))
    (array-signed-byte-32 . (signed-byte 32))
    (array-signed-byte-64 . (signed-byte 64))
    (array-single-float . single-float)
    (array-double-float . double-float)
    (array-complex-single-float . (complex single-float))
    (array-complex-double-float . (complex double-float))))

(defun class-element-type (class)
  (dolist (c (clostrophilia:class-precedence-list class) t)
    (let ((entry (assoc (class-name c) *element-types*)))
      (when entry (return (cdr entry))))))

;;; The classes of complex arrays, and what the kernel needs to know about
;;; them: :STRING, :VECTOR or :ARRAY. The kernel asks about any object
;;; (STRINGP, VECTORP, LENGTH...), also from inside generic function
;;; dispatch, so the answer comes from an alist computed when this file
;;; is loaded, without calling generic functions.
(defparameter *class-kinds*
  (let ((root (cl:find-class 'array))
        (result '()))
    (labels ((walk (class)
               (unless (assoc class result)
                 (unless (clostrophilia::class-finalized-p class)
                   (clostrophilia::finalize-inheritance class))
                 (let ((cpl (clostrophilia:class-precedence-list class)))
                   (push (cons class
                               (cond ((member (cl:find-class 'string) cpl) :string)
                                     ((member (cl:find-class 'vector) cpl) :vector)
                                     (t :array)))
                         result))
                 (mapc #'walk (clostrophilia:class-direct-subclasses class)))))
      (walk root))
    result))

;;; The kinds by stamp (an instance's stamp is its class's unique number):
;;; the kernel asks about every instance, mostly of other classes.
(defparameter *stamp-kinds*
  (let ((kinds (kiln.kernel::make-simple-vector
                (1+ (loop for (class) in *class-kinds*
                          maximize (clostrophilia::unique-number class)))
                nil)))
    (loop for (class . kind) in *class-kinds*
          do (setf (svref kinds (clostrophilia::unique-number class)) kind))
    kinds))

(defun complex-array-kind (object)
  (if (clostrophilia::instancep object)
      (let ((stamp (clostrophilia::standard-instance-access object -2))
            (kinds *stamp-kinds*))
        (and (< stamp (length kinds)) (svref kinds stamp)))
      nil))

;;; Element types are looked up often (each store checks the element), so
;;; the element type of each class and the upgraded element type of each
;;; type specifier are cached.
(defvar *class-element-types* '())      ; (class . element-type)

(defparameter *stamp-element-types*
  (let ((types (kiln.kernel::make-simple-vector (length *stamp-kinds*))))
    (loop for (class) in *class-kinds*
          do (setf (svref types (clostrophilia::unique-number class))
                   (list (class-element-type class))))
    types))

(defun element-type (array)
  (let* ((stamp (kiln.sys:%primop :standard-instance-access array -2))
         (types *stamp-element-types*)
         (entry (when (locally (declare (optimize (safety 0)))
                        (< (the fixnum stamp) (the fixnum (kiln.sys:%primop :length types))))
                  (kiln.sys:%primop :svref-unchecked types stamp))))
    (when entry (return-from element-type (car entry))))
  (let* ((class (clostrophilia::physical-class-of array))
         (entry (assoc class *class-element-types* :test #'eq)))
    (if entry
        (cdr entry)
        (let ((type (class-element-type class)))
          (push (cons class type) *class-element-types*)
          type))))

(defvar *upgraded-element-types* '())
(defvar *upgraded-element-types-version* -1)

(defun compute-upgraded-element-type (type environment)
  (dolist (candidate kiln.sys::*array-element-type-upgrades* t)
    (when (subtypep type candidate environment)
      (return candidate))))

(defun upgraded-array-element-type (type &optional environment)
  (cond ((eq type '*) '*)
        ((eq type t) t)
        ((eq type 'character) 'character)
        (environment (compute-upgraded-element-type type environment))
        (t
         (let ((version (kiln.kernel::type-assumption-version)))
           (unless (eql version *upgraded-element-types-version*)
             (setf *upgraded-element-types* nil *upgraded-element-types-version* version)))
         (multiple-value-bind (key cachep) (ctype::type-cache-key type)
           (let ((entry (and cachep (assoc key *upgraded-element-types* :test #'equal))))
             (if entry (cdr entry)
                 (let ((upgraded (compute-upgraded-element-type type nil)))
                   (when cachep (push (cons key upgraded) *upgraded-element-types*))
                   upgraded)))))))

(defun default-element (element-type)
  ;; ELEMENT-TYPE is an upgraded element type (*ELEMENT-TYPES*).
  (cond ((member element-type '(character base-char)) #\Space)
        ((null element-type) nil)
        ((eq element-type 'double-float) 0d0)
        ((eq element-type 'single-float) 0f0)
        ((eq element-type t) nil)
        ((equal element-type '(complex single-float)) nil)
        ((equal element-type '(complex double-float)) nil)
        (t 0)))

;;; Accessors

(defun dimensions (array)
  (array-dimensions array))

(defun vector-storage-layout (name &optional simple-string)
  (let* ((class (cl:find-class name))
         (slots (clostrophilia:class-slots class)))
    (flet ((location (slot)
             (clostrophilia:slot-definition-location
              (find slot slots :key #'clostrophilia:slot-definition-name))))
      (let ((stamp (clostrophilia::unique-number class)))
        (if simple-string
            (cl:vector stamp (location '%underlying-array) (location '%fill-pointer)
                       (location '%adjustable) (location '%contents))
            (cl:vector stamp (location '%dimensions) (location '%underlying-array)
                       (location '%fill-pointer) (location '%contents)))))))

(setf kiln.kernel::*single-float-vector-layout* (vector-storage-layout 'vector-single-float))
(setf kiln.kernel::*double-float-vector-layout* (vector-storage-layout 'vector-double-float))
(setf kiln.kernel::*base-string-layout* (vector-storage-layout 'vector-base-char t))
(defparameter *character-vector-layout* (vector-storage-layout 'string))

(defun kiln.kernel::%float-vector-typep (object type)
  (let ((layout (if (eq (second type) 'double-float)
                    kiln.kernel::*double-float-vector-layout*
                    kiln.kernel::*single-float-vector-layout*))
        (size (third type)))
    (if (and (kiln.sys:%primop :standard-instance-p object)
             (eql (kiln.sys:%primop :standard-instance-access object -2) (svref layout 0)))
        (let ((dimensions
                (if (null (kiln.sys:%primop :standard-instance-access object (svref layout 2)))
                    (kiln.sys:%primop :standard-instance-access object (svref layout 1))
                    (dimensions object))))
          (and (consp dimensions) (null (cdr dimensions))
               (or (eq size '*) (eql size (car dimensions)))))
        (typep object type))))

(defun total-size (array)
  (let ((size 1))
    (dolist (d (dimensions array) size)
      (setf size (* size d)))))

(declaim (inline storage-ref storage-set check-vector-subscript))

(defconstant +bit-storage-word-bits+ 62)
(defconstant +bit-storage-word-mask+ most-positive-fixnum)

(declaim (inline bit-storage-word-index bit-storage-offset bit-storage-ref set-bit-storage-ref))
(defun bit-storage-word-index (index)
  (kiln.sys:%primop :fixnum-quotient index +bit-storage-word-bits+))

(defun bit-storage-offset (index word-index)
  (locally (declare (optimize (safety 0)))
    (the fixnum (- (the fixnum index)
                   (the fixnum (* (the fixnum word-index) +bit-storage-word-bits+))))))

(defun bit-storage-ref (storage index)
  (let* ((word-index (bit-storage-word-index index))
         (word (kiln.sys:%primop :svref-unchecked storage word-index))
         (offset (bit-storage-offset index word-index)))
    (kiln.sys:%primop :fixnum-logand (kiln.sys:%primop :fixnum-shift-right word offset) 1)))

(defun set-bit-storage-ref (storage index value)
  (let* ((word-index (bit-storage-word-index index))
         (word (kiln.sys:%primop :svref-unchecked storage word-index))
         (offset (bit-storage-offset index word-index))
         (clear (kiln.sys:%primop :fixnum-logxor +bit-storage-word-mask+
                                (kiln.sys:%primop :fixnum-shift-left 1 offset)))
         (bits (kiln.sys:%primop :fixnum-shift-left value offset)))
    (kiln.sys:%primop :set-svref-unchecked storage word-index
      (kiln.sys:%primop :fixnum-logior (kiln.sys:%primop :fixnum-logand word clear) bits))
    value))

(defun storage-ref (array index)
  (let ((element-type (element-type array))
        (target (underlying-array array)))
    (when (null element-type)
      (error 'type-error :datum nil :expected-type nil))
    (cond (target (cl:row-major-aref target (+ index (displaced-index-offset array))))
          ((eq element-type 'cl:bit) (bit-storage-ref (contents array) index))
          ((eq element-type 'double-float)
           (kiln.sys:%primop :double-storage-ref (contents array) index))
          (t (cl:aref (contents array) index)))))

(defun storage-set (array value index)
  (let ((element-type (element-type array)))
    (unless (or (eq element-type t)
                (if (eq element-type 'character)
                    (characterp value)
                    (typep value element-type)))
      (error 'type-error :datum value :expected-type element-type))
    (let ((target (underlying-array array)))
      (cond (target (setf (cl:row-major-aref target (+ index (displaced-index-offset array))) value))
            ((eq element-type 'cl:bit) (set-bit-storage-ref (contents array) index value))
            ((eq element-type 'double-float)
             (kiln.sys:%primop :double-storage-set (contents array) index value))
            (t (setf (cl:aref (contents array) index) value))))))

(defun check-row-major-index (array index)
  (unless (and (integerp index) (<= 0 index) (< index (total-size array)))
    (error 'row-major-index-must-be-non-negative-and-less-than-total-size
           :array array :index index)))

(defun row-major-index (array subscripts)
  (let ((dimensions (dimensions array))
        (result 0)
        (number 0))
    (unless (= (length dimensions) (length subscripts))
      (error 'number-of-subscripts-must-equal-array-rank
             :subscripts subscripts :array array))
    (do ((s subscripts (cdr s))
         (d dimensions (cdr d)))
        ((null s) result)
      (unless (and (integerp (car s)) (<= 0 (car s)) (< (car s) (car d)))
        (error 'subscript-must-be-non-negative-and-less-than-dimension
               :array array :subscript-number number))
      (setf result (+ (* result (car d)) (car s))
            number (+ number 1)))))

;;; Fixed-arity access avoids allocating subscript lists for vectors. Bounds
;;; use the dimension, not the fill pointer, as required by AREF.
(defun check-vector-subscript (array index)
  (let ((dimensions (dimensions array)))
    (unless (and dimensions (null (cdr dimensions)))
      (error 'number-of-subscripts-must-equal-array-rank
             :subscripts (list index) :array array))
    (unless (and (integerp index) (<= 0 index) (< index (car dimensions)))
      (error 'subscript-must-be-non-negative-and-less-than-dimension
             :array array :subscript-number 0))))

(defun unsigned-fixnum-element-limit (type)
  (when (and (consp type) (eq (car type) 'unsigned-byte)
             (<= (cadr type) (integer-length most-positive-fixnum)))
    (1- (ash 1 (cadr type)))))

(defparameter *specialized-array-storage-slots*
  (let ((layouts (kiln.kernel::make-simple-vector (length *stamp-kinds*) nil)))
    (dolist (entry *class-kinds* layouts)
      (let* ((class (car entry))
             (slots (clostrophilia:class-slots class))
             (contents (find '%contents slots :key #'clostrophilia:slot-definition-name))
             (dimensions (find '%dimensions slots :key #'clostrophilia:slot-definition-name))
             (target (find '%underlying-array slots :key #'clostrophilia:slot-definition-name)))
        (when (and contents dimensions target)
          (let ((contents (clostrophilia:slot-definition-location contents))
                (dimensions (clostrophilia:slot-definition-location dimensions))
                (target (clostrophilia:slot-definition-location target)))
            (when (and (integerp contents) (integerp dimensions) (integerp target))
              (let ((type (class-element-type class)))
                (setf (svref layouts (clostrophilia::unique-number class))
                      (cl:vector contents dimensions target type
                                 (unsigned-fixnum-element-limit type)))))))))))

;; The stamp identifies the layout carried by this instance. An array
;; with another stamp uses ordinary slot lookup.
(declaim (inline specialized-array-storage-layout specialized-array-contents
                 simple-specialized-vector-storage))
(defun specialized-array-storage-layout (array)
  (let* ((stamp (kiln.sys:%primop :standard-instance-access array -2))
         (layouts *specialized-array-storage-slots*))
    (when (locally (declare (optimize (safety 0)))
            (< (the fixnum stamp) (the fixnum (kiln.sys:%primop :length layouts))))
      (kiln.sys:%primop :svref-unchecked layouts stamp))))

(defun specialized-array-contents (array layout)
  (if layout
      (kiln.sys:%primop :standard-instance-access array (kiln.sys:%primop :svref-unchecked layout 0))
      (slot-value array '%contents)))

(defun kiln.kernel::%simple-specialized-array-contents (array)
  (specialized-array-contents array (specialized-array-storage-layout array)))

(declaim (inline specialized-array-dimensions))
(defun specialized-array-dimensions (array layout)
  (if layout
      (kiln.sys:%primop :standard-instance-access array (kiln.sys:%primop :svref-unchecked layout 1))
      (slot-value array '%dimensions)))

(declaim (inline direct-boxed-vector-storage))
(defun direct-boxed-vector-storage (array index layout)
  (when layout
    (let ((type (kiln.sys:%primop :svref-unchecked layout 3)))
      (when (and type (not (eq type 'cl:bit))
                 (null (kiln.sys:%primop :standard-instance-access array
                                        (kiln.sys:%primop :svref-unchecked layout 2)))
                 (kiln.sys:%primop :fixnump index))
        (let ((dims (specialized-array-dimensions array layout))
              (storage (specialized-array-contents array layout)))
          (when (and (consp dims) (null (cdr dims))
                     (kiln.sys:%primop :simple-vector-p storage)
                     (locally (declare (optimize (safety 0)))
                       (and (<= 0 (the fixnum index))
                            (< (the fixnum index) (the fixnum (car dims))))))
            storage))))))

(defun vector-ref (array index)
  (let* ((layout (specialized-array-storage-layout array))
         (storage (direct-boxed-vector-storage array index layout)))
    (if storage
        (kiln.sys:%primop :svref-unchecked storage index)
        (progn (check-vector-subscript array index)
               (storage-ref array index)))))

(defun vector-set (array index value)
  (let* ((layout (specialized-array-storage-layout array))
         (storage (direct-boxed-vector-storage array index layout)))
    (if (and storage
             (let ((limit (kiln.sys:%primop :svref-unchecked layout 4)))
               (if limit
                   (and (kiln.sys:%primop :fixnump value)
                        (locally (declare (optimize (safety 0)))
                          (and (<= 0 (the fixnum value))
                               (<= (the fixnum value) (the fixnum limit)))))
                   (let ((type (kiln.sys:%primop :svref-unchecked layout 3)))
                     (or (eq type t) (typep value type))))))
        (kiln.sys:%primop :set-svref-unchecked storage index value)
        (progn (check-vector-subscript array index)
               (storage-set array value index)))))

(defun kiln.kernel::%simple-specialized-vector-contents (array)
  (let* ((layout (specialized-array-storage-layout array))
         (dimensions (specialized-array-dimensions array layout)))
    (when (and (consp dimensions) (null (cdr dimensions)))
      (specialized-array-contents array layout))))

(defun simple-specialized-vector-storage (array index rank-one)
  (let* ((layout (specialized-array-storage-layout array))
         (storage (specialized-array-contents array layout))
         (limit (if rank-one
                    (kiln.sys:%primop :length storage)
                    (let ((dimensions (specialized-array-dimensions array layout)))
                      (and (consp dimensions) (null (cdr dimensions)) (car dimensions))))))
    (unless (and limit
                 (kiln.sys:%primop :fixnump index)
                 (locally (declare (optimize (safety 0)))
                   (let ((index (the fixnum index)))
                     (and (<= 0 index) (< index (the fixnum limit))))))
      (check-vector-subscript array index))
    storage))

(defun kiln.kernel::%simple-specialized-aref-1 (array index rank-one)
  (let ((storage (simple-specialized-vector-storage array index rank-one)))
    (if (kiln.sys:%primop :double-storage-p storage)
        (kiln.sys:%primop :double-storage-ref storage index)
        (kiln.sys:%primop :svref-unchecked storage index))))

(defun kiln.kernel::%set-simple-specialized-aref-1 (value array index rank-one)
  (let ((storage (simple-specialized-vector-storage array index rank-one)))
    (if (kiln.sys:%primop :double-storage-p storage)
        (kiln.sys:%primop :double-storage-set storage index value)
        (kiln.sys:%primop :set-svref-unchecked storage index value))))

;;; General array operations call the storage helpers out of line.
(declaim (notinline storage-ref storage-set))

(defun fill-pointer-of (array)
  (if (typep array 'vector) (vector-fill-pointer array) nil))

(defun array-is-simple (array)
  (and (null (underlying-array array))
       (not (adjustable array))
       (null (fill-pointer-of array))))

(declaim (inline boxed-array-access-layout))
(defun boxed-array-access-layout (array store value)
  (let ((layout (specialized-array-storage-layout array)))
    (when (and layout
               (null (kiln.sys:%primop :standard-instance-access
                                       array (kiln.sys:%primop :svref-unchecked layout 2))))
      (let ((type (kiln.sys:%primop :svref-unchecked layout 3))
            (limit (kiln.sys:%primop :svref-unchecked layout 4)))
        (when (and type (not (eq type 'cl:bit))
                   (or (not store)
                       (eq type t)
                       (and limit (kiln.sys:%primop :fixnump value)
                            (locally (declare (optimize (safety 0)))
                              (<= 0 (the fixnum value) (the fixnum limit))))))
          layout)))))

(defun direct-boxed-array-access (array subscripts store value)
  (let ((layout (boxed-array-access-layout array store value)))
    (unless layout (return-from direct-boxed-array-access nil))
    (let ((storage (specialized-array-contents array layout))
          (dimensions (specialized-array-dimensions array layout))
          (index 0))
      (declare (fixnum index))
      ;; A zero dimension could follow a very large prefix.
      (unless (and (kiln.sys:%primop :simple-vector-p storage)
                   (not (eq (kiln.sys:%primop :length storage) 0)))
        (return-from direct-boxed-array-access nil))
      (loop while (and (consp dimensions) (consp subscripts))
            for subscript = (car subscripts)
            for dimension = (car dimensions)
            do (unless (and (kiln.sys:%primop :fixnump subscript)
                            (locally (declare (optimize (safety 0)))
                              (and (<= 0 (the fixnum subscript))
                                   (< (the fixnum subscript) (the fixnum dimension)))))
                 (return-from direct-boxed-array-access nil))
               (locally (declare (optimize (safety 0)))
                 (setf index (the fixnum (+ (the fixnum (* index (the fixnum dimension)))
                                             (the fixnum subscript)))))
               (setf dimensions (cdr dimensions) subscripts (cdr subscripts)))
      (when (and (null dimensions) (null subscripts))
        (values t (if store
                      (kiln.sys:%primop :set-svref-unchecked storage index value)
                      (kiln.sys:%primop :svref-unchecked storage index)))))))

(declaim (inline ranked-fixnum-subscript-p ranked-index-step))
(defun ranked-fixnum-subscript-p (subscript dimension)
  (and (kiln.sys:%primop :fixnump subscript)
       (kiln.sys:%primop :fixnum-index-below subscript dimension)))

(defun ranked-index-step (prefix dimension subscript)
  (kiln.sys:%primop :fixnum+ (kiln.sys:%primop :fixnum* prefix dimension) subscript))

(defun fixed-ranked-array-access (array i j k rank store value)
  (declare (notinline cl:aref (setf cl:aref)))
  (let ((layout (boxed-array-access-layout array store value)))
    (when layout
      (let ((storage (specialized-array-contents array layout))
            (dimensions (specialized-array-dimensions array layout))
            (three (eq rank 3)))
        (when (kiln.sys:%primop :simple-vector-p storage)
          (let ((di (first dimensions)) (dj (second dimensions)) (dk (third dimensions)))
            (when (and dj (if three (and dk (null (cdddr dimensions))) (null dk))
                       (ranked-fixnum-subscript-p i di)
                       (ranked-fixnum-subscript-p j dj)
                       (or (not three) (ranked-fixnum-subscript-p k dk)))
              ;; Checked indices are below the dimensions, so each prefix
              ;; fits within the size of the native backing vector.
              (let* ((ij (ranked-index-step i dj j))
                     (index (if three (ranked-index-step ij dk k) ij)))
                (return-from fixed-ranked-array-access
                  (if store (kiln.sys:%primop :set-svref-unchecked storage index value)
                      (kiln.sys:%primop :svref-unchecked storage index))))))))))
  (if store
      (if (eq rank 2) (setf (cl:aref array i j) value) (setf (cl:aref array i j k) value))
      (if (eq rank 2) (cl:aref array i j) (cl:aref array i j k))))

(defmacro define-two-index-array-access (name store)
  `(defun ,name (,@(when store '(value)) array i j)
     (declare (notinline ,(if store '(setf cl:aref) 'cl:aref)))
     (let ((layout (and (kiln.sys:%primop :standard-instance-p array)
                        (boxed-array-access-layout array ,store ,(when store 'value)))))
       (when layout
         (let ((storage (specialized-array-contents array layout))
               (dimensions (specialized-array-dimensions array layout)))
           (when (and (kiln.sys:%primop :simple-vector-p storage)
                      (consp (cdr dimensions)) (null (cddr dimensions))
                      (ranked-fixnum-subscript-p i (first dimensions))
                      (ranked-fixnum-subscript-p j (second dimensions)))
             (let ((index (ranked-index-step i (second dimensions) j)))
               (return-from ,name
                 ,(if store '(kiln.sys:%primop :set-svref-unchecked storage index value)
                      '(kiln.sys:%primop :svref-unchecked storage index))))))))
     ,(if store '(setf (cl:aref array i j) value) '(cl:aref array i j))))

(define-two-index-array-access kiln.kernel::%aref-2 nil)
(define-two-index-array-access kiln.kernel::%set-aref-2 t)

;;; The kernel's entry point (the operations are keywords).
(defun complex-array-op (op array &rest args)
  (ecase op
    (:aref
     (multiple-value-bind (found result) (direct-boxed-array-access array args nil nil)
       (if found result (storage-ref array (row-major-index array args)))))
    (:set-aref
     (let ((value (first args)) (subscripts (rest args)))
       (multiple-value-bind (found result) (direct-boxed-array-access array subscripts t value)
         (if found result (storage-set array value (row-major-index array subscripts))))))
    (:row-major-aref
     (check-row-major-index array (first args))
     (storage-ref array (first args)))
    (:set-row-major-aref
     (check-row-major-index array (second args))
     (storage-set array (first args) (second args)))
    (:length (or (fill-pointer-of array) (first (dimensions array))))
    (:array-rank (length (dimensions array)))
    (:array-dimensions (copy-list (dimensions array)))
    (:array-total-size (total-size array))
    (:array-element-type (element-type array))
    (:simple-array-p (array-is-simple array))
    (:make-like (cl:make-array (first args) :element-type (element-type array)))
    ;; The native vector that holds a one-dimensional array's elements at
    ;; the same indices, or NIL (displaced): REPLACE copies into and out of
    ;; it directly.
    (:native-storage
     (and (null (underlying-array array))
          (not (member (element-type array) '(cl:bit double-float)))
          (= (length (dimensions array)) 1)
          (contents array)))))

(setf kiln.kernel::*complex-array-kind* #'complex-array-kind
      kiln.kernel::*complex-array-op* #'complex-array-op
      kiln.kernel::*complex-array-ranked-access* #'fixed-ranked-array-access
      kiln.kernel::*complex-array-ref-1* #'vector-ref
      kiln.kernel::*complex-array-set-1* #'vector-set)

(setf clostrophilia::*public-class-of*
      (lambda (object)
        (let ((kind (complex-array-kind object)))
          (when kind
            (cl:find-class
             (case kind
               (:string (if (array-is-simple object) 'cl:simple-string 'cl:string))
               (:vector
                (if (eq (element-type object) 'bit)
                    (if (array-is-simple object) 'cl:simple-bit-vector 'cl:bit-vector)
                    (if (and (array-is-simple object) (eq (element-type object) t))
                        'cl:simple-vector 'cl:vector)))
               (t (if (array-is-simple object) 'cl:simple-array 'cl:array))))))))

;;; ctype's view of arrays.
(defmethod ctype:upgraded-array-element-type ((client ctype::kiln-client) specifier
                                              &optional environment)
  (upgraded-array-element-type specifier environment))

(defmethod ctype:simple-array-p ((client ctype::kiln-client) object)
  (kiln.kernel::simple-array-p object))

(defmethod ctype:string-uaets ((client ctype::kiln-client))
  '(base-char character))

(defun cl:make-string (size &key (initial-element #\Space) (element-type 'character))
  (let ((upgraded (upgraded-array-element-type element-type)))
    (unless (member upgraded '(base-char character))
      (error 'type-error :datum element-type :expected-type '(member base-char character)))
    (if (eq upgraded 'character)
        (kiln.sys:%primop :make-string size (kiln.kernel::check-character initial-element))
        (cl:make-array size :element-type upgraded :initial-element initial-element))))

;;; MAKE-ARRAY

(defun canonical-dimensions (dimensions)
  (check-and-canonicalize-dimensions dimensions))

(defun make-storage (element-type size initial-element)
  (cond ((member element-type '(character base-char))
         (kiln.kernel::make-string size :initial-element initial-element))
        ((eq element-type 'cl:bit)
         (kiln.kernel::make-simple-vector (bit-storage-word-index (+ size (1- +bit-storage-word-bits+)))
           (if (zerop initial-element) 0 +bit-storage-word-mask+)))
        ((eq element-type 'double-float)
         (kiln.sys:%primop :make-double-storage size initial-element))
        (t (kiln.kernel::make-array size :initial-element initial-element))))

(defun fill-from-contents (array dimensions contents)
  (let ((index 0))
    (labels ((walk (dimensions contents)
               (if (null dimensions)
                   (progn (storage-set array contents index)
                          (setf index (+ index 1)))
                   (progn
                     (unless (= (length contents) (first dimensions))
                       (error 'incorrect-contents-length
                              :contents contents
                              :expected-length (first dimensions)))
                     (map nil (lambda (c) (walk (rest dimensions) c)) contents)))))
      (walk dimensions contents))))

(defun native-array-p (dimensions element-type adjustable fill-pointer displaced-to)
  (and (consp dimensions) (null (rest dimensions))
       (not adjustable) (null fill-pointer) (null displaced-to)
       (member element-type '(t character))))

(defun cl:make-array (dimensions &key (element-type t)
                                      (initial-element nil initial-element-p)
                                      (initial-contents nil initial-contents-p)
                                      adjustable fill-pointer
                                      displaced-to (displaced-index-offset 0))
  ;; The common case without SUBTYPEP (ctype makes vectors).
  (when (and (or (eq element-type t) (eq element-type 'character))
             (or (and (integerp dimensions) (not (minusp dimensions)))
                 (and (consp dimensions) (null (cdr dimensions))
                      (integerp (car dimensions)) (not (minusp (car dimensions)))))
             (not adjustable) (null fill-pointer) (null displaced-to))
    (let* ((n (if (consp dimensions) (car dimensions) dimensions))
           (vector (if (eq element-type t)
                       (kiln.kernel::make-simple-vector
                        n (if initial-element-p initial-element nil))
                       (kiln.kernel::make-string
                        n :initial-element (if initial-element-p initial-element #\Space)))))
      (when initial-contents-p
        (let ((i 0))
          (map nil (lambda (x) (setf (cl:aref vector i) x) (setf i (+ i 1)))
               initial-contents)))
      (return-from cl:make-array vector)))
  (let* ((dimensions (canonical-dimensions dimensions))
         (uaet (upgraded-array-element-type element-type))
         (size (let ((n 1)) (dolist (d dimensions n) (setf n (* n d)))))
         (vectorp (and (consp dimensions) (null (rest dimensions)))))
    (when (and initial-element-p initial-contents-p)
      (error 'initial-contents-and-initial-element-cannot-both-be-supplied))
    (when (and displaced-to (or initial-element-p initial-contents-p))
      (error 'initial-contents-cannot-be-supplied-for-displaced-array))
    (when (and fill-pointer (not vectorp))
      (error "A fill pointer requires a vector: ~s" dimensions))
    (when (and initial-element-p (not (typep initial-element uaet)))
      (error 'type-error :datum initial-element :expected-type uaet))
    (let ((initial (if initial-element-p initial-element (default-element uaet))))
      (if (native-array-p dimensions uaet adjustable fill-pointer displaced-to)
          (let ((vector (make-storage uaet size initial)))
            (when initial-contents-p
              (let ((i 0))
                (map nil (lambda (x) (setf (cl:aref vector i) x) (setf i (+ i 1)))
                     initial-contents)))
            vector)
          (let* ((class-name (if vectorp
                                 (vector-class-name-from-element-type uaet nil)
                                 (non-vector-class-name-from-element-type uaet nil)))
                 (array (make-instance class-name
                                       :dimensions dimensions
                                       :adjustable adjustable)))
            (when vectorp
              (setf (vector-fill-pointer array)
                    (cond ((eq fill-pointer t) size)
                          ((null fill-pointer) nil)
                          ((and (integerp fill-pointer) (<= 0 fill-pointer size))
                           fill-pointer)
                          (t (error 'type-error :datum fill-pointer
                                                :expected-type `(integer 0 ,size))))))
            (if displaced-to
                (progn
                  (unless (<= (+ displaced-index-offset size)
                              (cl:array-total-size displaced-to))
                    (error "The displaced array is too small: ~s" displaced-to))
                  (setf (underlying-array array) displaced-to
                        (displaced-index-offset array) displaced-index-offset))
                (progn
                  (setf (contents array) (make-storage uaet size initial))
                  (when initial-contents-p
                    (fill-from-contents array dimensions initial-contents))))
            array)))))

;;; Fill pointers

(defun check-fill-pointer (vector)
  (unless (and (typep vector 'vector) (vector-fill-pointer vector))
    (error 'type-error :datum vector :expected-type '(and vector (not simple-array))))
  vector)

(defun cl:array-has-fill-pointer-p (array)
  (unless (cl:arrayp array)
    (error 'type-error :datum array :expected-type 'cl:array))
  (if (and (typep array 'vector) (vector-fill-pointer array)) t nil))

(defun cl:fill-pointer (vector)
  (vector-fill-pointer (check-fill-pointer vector)))

(defun (setf cl:fill-pointer) (new vector)
  (check-fill-pointer vector)
  (unless (and (integerp new) (<= 0 new (first (dimensions vector))))
    (error 'type-error :datum new
                       :expected-type `(integer 0 ,(first (dimensions vector)))))
  (setf (vector-fill-pointer vector) new))

(defun cl:vector-push (element vector)
  (let ((fp (vector-fill-pointer (check-fill-pointer vector))))
    (if (< fp (first (dimensions vector)))
        (progn (storage-set vector element fp)
               (setf (vector-fill-pointer vector) (+ fp 1))
               fp)
        nil)))

;;; Resizing an adjustable vector that is not displaced replaces its native
;;; storage, copying the elements that remain (the common case of
;;; ADJUST-ARRAY and VECTOR-PUSH-EXTEND). New elements are INITIAL-ELEMENT.
(defun copy-bit-storage-prefix (new old size)
  (let* ((words (bit-storage-word-index size))
         (tail (bit-storage-offset size words)))
    (replace new old :end2 words)
    (unless (zerop tail)
      (let ((mask (1- (kiln.sys:%primop :fixnum-shift-left 1 tail))))
        (setf (svref new words)
              (logior (logand (svref old words) mask)
                      (logandc2 (svref new words) mask)))))))

(defun resize-vector (vector size initial-element)
  (let* ((old (contents vector))
         (bitp (eq (element-type vector) 'cl:bit))
         (doublep (eq (element-type vector) 'double-float))
         (new (if (or bitp doublep)
                  (progn
                    (unless (valid-dimension-p size)
                      (error 'invalid-dimensions :dimensions size))
                    (if bitp (check-type initial-element cl:bit)
                        (check-type initial-element double-float))
                    (make-storage (element-type vector) size initial-element))
                  (make-storage (if (stringp old) 'character t) size initial-element))))
    (cond (bitp (copy-bit-storage-prefix new old (min size (first (dimensions vector)))))
          (doublep
           (dotimes (i (min size (first (dimensions vector))))
             (kiln.sys:%primop :double-storage-set new i
               (kiln.sys:%primop :double-storage-ref old i))))
          (t (replace new old :end2 (min size (length old)))))
    (setf (contents vector) new
          (array-dimensions-slot vector) (list size))
    (let ((fp (vector-fill-pointer vector)))
      (when (and fp (> fp size))
        (setf (vector-fill-pointer vector) size)))
    vector))

(defun resizable-vector-p (array)
  (and (adjustable array) (null (underlying-array array)) (typep array 'vector)))

(defun cl:vector-push-extend (element vector &optional (extension 16))
  (let ((layout kiln.kernel::*base-string-layout*))
    (when (and layout (kiln.sys:%primop :standard-instance-p vector)
               (eq (kiln.sys:%primop :standard-instance-access vector -2)
                   (kiln.sys:%primop :svref-unchecked layout 0))
               (null (kiln.sys:%primop :standard-instance-access
                                      vector (kiln.sys:%primop :svref-unchecked layout 1))))
      (let* ((slot (kiln.sys:%primop :svref-unchecked layout 2))
             (fill (kiln.sys:%primop :standard-instance-access vector slot)))
        (when (and (kiln.sys:%primop :fixnump fill)
                   (kiln.sys:%primop :characterp element))
          (let ((storage (kiln.sys:%primop :standard-instance-access
                                         vector (kiln.sys:%primop :svref-unchecked layout 4))))
            (locally (declare (optimize (speed 3) (safety 0)))
              (when (and (< (the fixnum (kiln.sys:%primop :char-code element)) 128)
                         (<= 0 (the fixnum fill))
                         (< (the fixnum fill) (the fixnum (kiln.sys:%primop :length storage))))
                (kiln.sys:%primop :set-schar-unchecked storage fill element)
                (kiln.sys:%primop :set-standard-instance-access vector slot (1+ (the fixnum fill)))
                (return-from cl:vector-push-extend fill))))))))
  (let ((fp (vector-fill-pointer (check-fill-pointer vector))))
    (when (>= fp (first (dimensions vector)))
      (if (resizable-vector-p vector)
          (resize-vector vector (+ fp (max extension 1 fp)) (default-element (element-type vector)))
          (cl:adjust-array vector (+ fp (max extension 1 fp)))))
    (cl:vector-push element vector)))

(defun cl:vector-pop (vector)
  (let ((fp (vector-fill-pointer (check-fill-pointer vector))))
    (when (zerop fp)
      (error "Cannot pop from an empty vector: ~s" vector))
    (setf (vector-fill-pointer vector) (- fp 1))
    (storage-ref vector (- fp 1))))

;;; Other array functions

(defun cl:adjustable-array-p (array)
  (cond ((kiln.kernel::native-vector-p array) nil)
        ((complex-array-kind array) (if (adjustable array) t nil))
        (t (error 'type-error :datum array :expected-type 'array))))

(defun cl:array-displacement (array)
  (cond ((kiln.kernel::native-vector-p array) (values nil 0))
        ((complex-array-kind array)
         (if (underlying-array array)
             (values (underlying-array array) (displaced-index-offset array))
             (values nil 0)))
        (t (error 'type-error :datum array :expected-type 'array))))

(defun cl:array-in-bounds-p (array &rest subscripts)
  (let ((dimensions (cl:array-dimensions array)))
    (and (= (length dimensions) (length subscripts))
         (every (lambda (s d) (and (integerp s) (<= 0 s) (< s d))) subscripts dimensions))))

(defun cl:array-row-major-index (array &rest subscripts)
  (if (kiln.kernel::native-vector-p array)
      (progn (cl:aref array (first subscripts)) ; checks the subscript
             (first subscripts))
      (row-major-index array subscripts)))

(defun cl:upgraded-array-element-type (type &optional environment)
  (upgraded-array-element-type type environment))

;;; ADJUST-ARRAY: an adjustable array is changed in place, any other array
;;; copied. Elements whose subscripts are valid in both the old and the
;;; new dimensions are kept.

(defun copy-elements (old old-dimensions new new-dimensions)
  (let ((rank (length new-dimensions)))
    (labels ((walk (axis old-index new-index)
               (if (= axis rank)
                   (setf (cl:row-major-aref new new-index)
                         (cl:row-major-aref old old-index))
                   (let ((od (nth axis old-dimensions))
                         (nd (nth axis new-dimensions)))
                     (dotimes (i (min od nd))
                       (walk (+ axis 1) (+ (* old-index od) i) (+ (* new-index nd) i)))))))
      (walk 0 0 0))))

(defun cl:adjust-array (array dimensions &key (element-type (cl:array-element-type array))
                                              (initial-element nil initial-element-p)
                                              (initial-contents nil initial-contents-p)
                                              fill-pointer
                                              displaced-to (displaced-index-offset 0))
  (when (and (not (kiln.kernel::native-vector-p array))
             (complex-array-kind array)
             (resizable-vector-p array)
             (null displaced-to) (not initial-contents-p)
             (or (integerp dimensions) (and (consp dimensions) (null (rest dimensions))))
             (equal (upgraded-array-element-type element-type) (element-type array)))
    (resize-vector array (if (consp dimensions) (first dimensions) dimensions)
                   (if initial-element-p initial-element (default-element (element-type array))))
    (when fill-pointer
      (setf (cl:fill-pointer array) (if (eq fill-pointer t) (first (dimensions array)) fill-pointer)))
    (return-from cl:adjust-array array))
  (let* ((dimensions (canonical-dimensions dimensions))
         (fill-pointer (if (and (null fill-pointer) (cl:array-has-fill-pointer-p array))
                           (cl:fill-pointer array)
                           fill-pointer))
         (new (apply #'cl:make-array dimensions
                     :element-type element-type
                     :fill-pointer fill-pointer
                     (append (if displaced-to
                                 (list :displaced-to displaced-to
                                       :displaced-index-offset displaced-index-offset)
                                 '())
                             (if initial-element-p (list :initial-element initial-element) '())
                             (if initial-contents-p (list :initial-contents initial-contents) '())
                             (if (cl:adjustable-array-p array) (list :adjustable t) '())))))
    (unless (or displaced-to initial-contents-p)
      (copy-elements array (cl:array-dimensions array) new dimensions))
    (if (cl:adjustable-array-p array)
        ;; Change ARRAY in place: it takes over the new array's contents.
        (progn
          (setf (array-dimensions-slot array) (dimensions new)
                (contents array) (contents new)
                (underlying-array array) (underlying-array new)
                (displaced-index-offset array) (displaced-index-offset new))
          (when (typep array 'vector)
            (setf (vector-fill-pointer array) (vector-fill-pointer new)))
          array)
        new)))

(defun (setf array-dimensions-slot) (dimensions array)
  (setf (slot-value array '%dimensions) dimensions))

;;; Bit arrays

(defun cl:bit (array &rest subscripts) (apply #'cl:aref array subscripts))
(defun cl:sbit (array &rest subscripts) (apply #'cl:aref array subscripts))
(defun (setf cl:bit) (bit array &rest subscripts)
  (apply #'(setf cl:aref) bit array subscripts))
(defun (setf cl:sbit) (bit array &rest subscripts)
  (apply #'(setf cl:aref) bit array subscripts))
;;; The bitwise operations on bit arrays (CLHS BIT-AND). RESULT is NIL (a
;;; new array), T (the first argument) or a bit array of the same
;;; dimensions.
(defun bit-array-result (array result)
  (cond ((null result)
         (cl:make-array (cl:array-dimensions array) :element-type 'cl:bit))
        ((eq result t) array)
        (t result)))

(defun bit-array-storage (array)
  (when (and (cl:arrayp array)
             (eq (cl:array-element-type array) 'cl:bit)
             (null (underlying-array array)))
    (contents array)))

(defun bit-array-op (function a b result)
  (dotimes (i (cl:array-total-size a) result)
    (setf (cl:row-major-aref result i)
          (logand 1 (funcall function (cl:row-major-aref a i) (cl:row-major-aref b i))))))

(defun bit-array-operands (a b result)
  (let ((shape (cl:array-dimensions a)))
    (unless (equal shape (cl:array-dimensions b))
      (error "The bit arrays ~S and ~S do not have the same dimensions." a b))
    (let ((result (bit-array-result a result)))
      ;; Matching shapes give the same packed word count.
      (if (equal shape (cl:array-dimensions result))
          (values result (bit-array-storage a) (bit-array-storage b)
                  (bit-array-storage result))
          (values result nil nil nil)))))

(macrolet ((define (name function expression)
             `(defun ,name (a b &optional result)
                (multiple-value-bind (result a-storage b-storage destination)
                    (bit-array-operands a b result)
                  (if (and a-storage b-storage destination)
                      (do ((index 0 (kiln.sys:%primop :fixnum+ index 1))
                           (limit (kiln.sys:%primop :length a-storage)))
                          ((kiln.sys:%primop :fixnum-le limit index) result)
                        (let ((x (kiln.sys:%primop :svref-unchecked a-storage index))
                              (y (kiln.sys:%primop :svref-unchecked b-storage index)))
                          (kiln.sys:%primop :set-svref-unchecked destination index ,expression)))
                      (bit-array-op ,function a b result)))))
           (and-bit (x y) `(kiln.sys:%primop :fixnum-logand ,x ,y))
           (or-bit (x y) `(kiln.sys:%primop :fixnum-logior ,x ,y))
           (xor-bit (x y) `(kiln.sys:%primop :fixnum-logxor ,x ,y))
           (not-bit (x) `(kiln.sys:%primop :fixnum-logxor ,x +bit-storage-word-mask+)))
  (define cl:bit-and #'logand (and-bit x y))
  (define cl:bit-ior #'logior (or-bit x y))
  (define cl:bit-xor #'logxor (xor-bit x y))
  (define cl:bit-eqv #'logeqv (not-bit (xor-bit x y)))
  (define cl:bit-nand #'lognand (not-bit (and-bit x y)))
  (define cl:bit-nor #'lognor (not-bit (or-bit x y)))
  (define cl:bit-andc1 #'logandc1 (and-bit (not-bit x) y))
  (define cl:bit-andc2 #'logandc2 (and-bit x (not-bit y)))
  (define cl:bit-orc1 #'logorc1 (or-bit (not-bit x) y))
  (define cl:bit-orc2 #'logorc2 (or-bit x (not-bit y))))

(defun cl:bit-not (bit-array &optional result)
  (let* ((result (bit-array-result bit-array result))
         (source (bit-array-storage bit-array))
         (destination (bit-array-storage result)))
    (if (and source destination
             (equal (cl:array-dimensions bit-array) (cl:array-dimensions result)))
        (do ((index 0 (kiln.sys:%primop :fixnum+ index 1))
             (limit (kiln.sys:%primop :length source)))
            ((kiln.sys:%primop :fixnum-le limit index) result)
          (kiln.sys:%primop :set-svref-unchecked destination index
            (kiln.sys:%primop :fixnum-logxor (kiln.sys:%primop :svref-unchecked source index)
                             +bit-storage-word-mask+)))
        (dotimes (i (cl:array-total-size bit-array) result)
          (setf (cl:row-major-aref result i) (- 1 (cl:row-major-aref bit-array i)))))))

(defun cl:bit-vector-p (object)
  (typep object 'cl:bit-vector))
(defun cl:simple-bit-vector-p (object)
  (and (typep object 'cl:bit-vector) (array-is-simple object)))
