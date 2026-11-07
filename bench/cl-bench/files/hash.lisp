;; hashtable and READ-LINE benchmarking code
;;
;; some code by Paul Foley
;; Time-stamp: <2016-05-10 13:11:57 jack>

(defpackage :cl-bench.hash
  (:use :common-lisp)
  (:export #:run-slurp-lines
           #:setup-string
           #:setup-fixnum
           #:setup-mixbag
           #:setup-number
           #:bench-htable
           #:bench-setget
           #:bench-setrem
           #:bench-sxhash))

(in-package :cl-bench.hash)


(defun read-many-lines (file)
  (with-open-file (f file :direction :input)
    (loop :for l = (read-line f nil)
          :while l
          :count (length l))))

(defun run-slurp-lines ()
  (cond ((probe-file "/usr/share/dict/words")
         (read-many-lines "/usr/share/dict/words"))
        ((probe-file "/usr/dict/words")
         (read-many-lines "/usr/dict/words"))))

(defparameter +alphanumeric+
  "0123456789ABCDEFabcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")

(defvar *table* nil)
(defvar *value* nil)
(defvar *keys* nil)

(defun random-string (length &optional (nchar (length +alphanumeric+)))
  (let ((string (make-string length)))
    (loop for i from 0 below length do
          (setf (aref string i)
                (aref +alphanumeric+ (random nchar))))
    string))

;;; This creates strings of form XXXXabcXXXX that is ith stable prefix and
;;; suffix. This generator is devised to bypass SBCL adaptive string hashing.
(defun random-string-non-adaptive (length nkeys)
  (let* ((string (make-string length))
         (chrlen (length +alphanumeric+))
         (meaningful-length (ceiling (log nkeys chrlen))))
    (loop with b1 = (floor (- length meaningful-length) 2)
          with b2 = (floor (+ length meaningful-length) 2)
          for i from 0 below length
          do (if (<= b1 i b2)
                 (setf (aref string i) (aref +alphanumeric+ (random chrlen)))
                 (setf (aref string i) #\X)))
    string))

;;; This setup generator is primarily meant to test hashing numbers under EQUALP
;;; predicate and stress-test scenarios where floats and rationals overlap or
;;; can overlap under various hasing assumptions.
;;;
;;; Recommended profiles:
;;;
;;; :AVERAGE - hashing real numbers (50% rationals, 50% floats)
;;; :TYPICAL - 25% fixnums, 25% bignums, 25% uuids (fixnum), 25% small floats
;;; :DYADIC  - rational and float numbers that can be exactly coerced under =
;;;
;;; Remaining profiles:
;;;
;;; :FIXNUM, :BIGNUM, :RATIO, :DOUBLE, :SINGLE, :FLOAT, :COMPLEX-FLOAT,
;;; :COMPLEX-RATIO - indivisual number types (randomized, without nudging)
;;;
;;; :PETITE - small doubles and small fixnums (avoids bignums and collisions).
;;;
;;; :COLLIDE - rationals that are in binary80 range but exceed the precision of
;;; binary64. Implementations representing LONG-FLOAT as a type that is bigger
;;; than DOUBLE-FLOAT, and which hash such rationals by casting to LONG-FLOAT
;;; and then to DOUBLE-FLOAT, will observe here degraded performance because all
;;; values collapse to either infinity or 0.
;;;
;;; :BEYOND-COLLISION - similar to the above, but rationals exceed the precision
;;; of binary128, so implementations recognizing that will avoid the collapse.
;;;
;;; :EVERYTHING combines profiles average, typical, dyadaic and complex numbers.
(defun setup-number (&key (table-size 300)
                       (table-test #'equalp)
                       (n-keys (expt 2 16))
                       (prefill 0)
                       (profile :all)
                     &aux (nasty-fixnum (expt 2 53)))
  (setq *table* (make-hash-table :test table-test :size table-size))
  (setq *value* (random 89))
  (labels ((s (x)
             (ecase (random 2) (0 x) (1 (- x))))
           (rand (min max)
             "random number [min,max]"
             (+ (random (+ (- max min) 1)) min))
           ;; Randomized rationals
           (gen-fixnum ()
             (rand most-negative-fixnum most-positive-fixnum))
           (gen-bignum ()
             (s (rand (1+ most-positive-fixnum) (expt 2 128))))
           (gen-ratio ()                ; 25% chance each
             (ecase (random 4)
               (0 (/ (gen-fixnum) (gen-fixnum)))
               (1 (/ (gen-bignum) (gen-fixnum)))
               (2 (/ (gen-fixnum) (gen-bignum)))
               (3 (/ (gen-bignum) (gen-bignum)))))
           (random-rational ()
             (ecase (random 3)
               (0 (gen-fixnum))
               (1 (gen-bignum))
               (2 (gen-ratio))))
           ;; Randomized floats (small fractions and large integers)
           (gen-float-small ()
             (ecase (random 4)
               (0 (s (random 20.0s0)))
               (1 (s (random 20.0f0)))
               (2 (s (random 20.0d0)))
               (3 (s (random 20.0l0)))))
           (gen-float-large ()
             (ecase (random 4)
               (0 (s (random most-positive-short-float)))
               (1 (s (random most-positive-single-float)))
               (2 (s (random most-positive-double-float)))
               (3 (s (random most-positive-long-float)))))
           (random-float ()
             (ecase (random 2)
               (0 (gen-float-small))
               (1 (gen-float-large))))
           (random-single ()
             (ecase (random 2)
               (0 (s (random 20.0f0)))
               (1 (s (random most-positive-single-float)))))
           (random-double ()
             (ecase (random 2)
               (0 (s (random 20.0d0)))
               (1 (s (random most-positive-double-float)))))
           ;; Randomized complexes (smoke)
           (random-complex-float ()
             (complex (random-float) (random-float)))
           (random-complex-ratio ()
             (complex (random-rational) (random-rational)))
           (random-complex ()
             (ecase (random 2)
               (0 (random-complex-float))
               (1 (random-complex-ratio))))
           ;; Small numbers (avoid bignums, tests float/fixnum)
           (random-petite ()
             (ecase (random 2)
               (0 (s (random 20.0d0)))
               (1 (s (random (expt 2 28))))))
           ;; Consecutive fixnums exceeding binary64 mantissa (2^53)
           (gen-nasty-fixnum () (incf nasty-fixnum))
           ;; We subtract fraction bits from the exponent to not overflow it.
           ;;
           ;; Only SINGLE-FLOAT and DOUBLE-FLOAT usually agree between different
           ;; implementations and architectures, so otherwise we must to be wary
           ;; of comparing apples to oranges. That said these are just numbers,
           ;; so comparing how implementations with different precisions combat
           ;; them is still valuable even when the underlying types differ.
           ;;
           ;; SHORT-FLOAT may be represented as FLOAT16, FLOAT32
           ;; SINGLE-FLOAT is likely represented as FLOAT32
           ;; DOUBLE-FLOAT is likely represented as FLOAT64
           ;; LONG-FLOAT may be represented as FLOAT64, FLOAT80 or FLOAT128
           ;; ARBITRARY-PRECISION-FLOAT (CLISP) could be FLOAT256
           ;;
           ;; Helpers below are used to construct bignums that overlap with
           ;; floats of the specified type. Care is taken to not sample numbers
           ;; that are representable by floats with lower precision. That means
           ;; in practice, that from float64 upwards
           ;;
           ;;   mantissa * 2^exponent - bignum
           ;;   mantissa / 2^exponent - x/bign
           ;;
           ;; SHORT-FLOAT, SINGLE-FLOAT and ARBITRARY-PRECISION-FLOAT are now
           ;; included for the reference, same for AUX-FLOAT-16, AUX-FLOAT-32
           ;; and AUX-FLOAT-256. Currently we don't test these.
           ;;
           ;; LONG-FLOAT and FLOAT80/FLOAT128 types are tested optionally.
           (aux-float (mantissa-bits exponent-bits min-exponent)
             (let ((fraction-bits (1- mantissa-bits))
                   (max-exponent (1- (expt 2 (1- exponent-bits)))))
               (decf max-exponent fraction-bits)
               (values (rand 1 (1- (expt 2 mantissa-bits)))
                       (expt 2 (rand min-exponent max-exponent)))))
           (aux-float-known (name)
             (ecase name
               #+ (or) (:binary16  (aux-float  11 5  0))
               #+ (or) (:binary32  (aux-float  24 8  16))
               (:binary64  (aux-float  53 11 128))
               (:binary80  (aux-float  64 15 1024))
               #+ (or) (:binary128 (aux-float 113 15 1024))
               #+ (or) (:binary256 (aux-float 237 19 16384))))
           ;; These are float-shaped rationals that should hash differently. A
           ;; good candidate for comparing implementations between each other.
           (gen-bignum/dfloat ()
             (multiple-value-bind (mantissa exponent)
                 (aux-float-known :binary64)
               (s (* mantissa exponent))))
           (gen-ratio/dfloat ()
             (multiple-value-bind (mantissa exponent)
                 (aux-float-known :binary64)
               (s (/ mantissa exponent))))
           ;; Using :BINARY80 is a safe bet for LONG-FLOAT (float80 is a subset
           ;; of float128). Note that if we hash as doubles, all values in this
           ;; range are first downcast to zero or infinity - in other they are
           ;; good to stress-test implementaions, but not good as a benchmark.
           (gen-bignum/lfloat ()
             (multiple-value-bind (mantissa exponent)
                 (aux-float-known :binary80)
               (s (* mantissa exponent))))
           (gen-ratio/lfloat ()
             (multiple-value-bind (mantissa exponent)
                 (aux-float-known :binary80)
               (s (/ mantissa exponent))))
           ;; These float minimally exceed :BINARY128 in precision while keeping
           ;; the mantissa in the precision of :BINARY64 -- this is a good test
           ;; for float-shaped rationals beyond existing float ranges.
           (gen-bignum/xfloat ()
             (multiple-value-bind (mantissa exponent) (aux-float 53 16 16384)
               (s (* mantissa exponent))))
           (gen-ratio/xfloat ()
             (multiple-value-bind (mantissa exponent) (aux-float 53 16 16384)
               (s (/ mantissa exponent))))
           ;; Instead of computing things again, we constructs exact floats from
           ;; rationals that have exact float value :3.
           (gen-dfloat/bignum () (s (float (gen-bignum/dfloat) 1.0d0)))
           (gen-dfloat/ratio  () (s (float (gen-ratio/dfloat)  1.0d0))))
    (setq *keys*
          (loop repeat n-keys
                for key = (ecase profile
                            ;; 50/50 rationals vs floats (all kinds)
                            (:average
                             (ecase (random 2)
                               (0 (random-rational))
                               (1 (random-float))))
                            ;; fixnums, uuids, small floats, (expt 2 N) bignums
                            (:typical
                             (ecase (random 4)
                               (0 (gen-fixnum))
                               (1 (gen-bignum/dfloat))
                               (2 (gen-nasty-fixnum))
                               (3 (gen-float-small))))
                            ;; Stess tests overlapping representations
                            (:dyadic
                             (ecase (random 5)
                               (0 (gen-fixnum))
                               (1 (gen-bignum/dfloat))
                               (2 (gen-ratio/dfloat))
                               (3 (gen-dfloat/bignum))
                               (4 (gen-dfloat/ratio))))
                            ;; Stress test scenarios where LONG-FLOAT after cast
                            ;; to DOUBLE-FLOAT is either 0 or infinity. This
                            ;; test is interesting only for implementations that
                            ;; have different LONG-FLOAT; otherwise they fast
                            ;; forward to hashing bignums and ratios directly
                            ;; and then this test is === :BEYOND-COLLISION.
                            (:collide
                             (ecase (random 2)
                               (0 (gen-bignum/lfloat))
                               (1 (gen-ratio/lfloat))))
                            ;; Similar to the above, but values are above long
                            ;; float precision, so a sufficiently smart runtime
                            ;; will avoid the trap and produce quality hashes.
                            (:beyond-collision
                             (ecase (random 2)
                               (0 (gen-bignum/xfloat))
                               (1 (gen-ratio/xfloat))))
                            ;; Individual types without any nudging
                            (:fixnum  (gen-fixnum))
                            (:bignum  (gen-bignum))
                            (:ratio   (gen-ratio))
                            (:float   (random-float))
                            (:double  (random-double))
                            (:single  (random-single))
                            (:petite  (random-petite))
                            (:complex-float (random-complex-float))
                            (:complex-ratio (random-complex-ratio))
                            ;; EVERYTHING (almost :3)
                            (:everything
                             (ecase (random 10)
                               (0 (random-rational))
                               (1 (random-float))
                               (2 (random-complex))
                               (3 (gen-nasty-fixnum))
                               (4 (gen-bignum/dfloat))
                               (5 (gen-bignum/xfloat))
                               (6 (gen-ratio/dfloat))
                               (7 (gen-ratio/xfloat))
                               (8 (gen-dfloat/bignum))
                               (9 (gen-dfloat/ratio)))))
                collect key
                do (unless (zerop prefill)
                     (decf prefill)
                     (setf (gethash key *table*) *value*))))))

#+ (or) ;; specialized profiles
(macrolet ((defb (name profile)
             `(defbench ,name
                :group :hash*
                :setup `(cl-bench.hash:setup-number :n-keys (expt 2 16)
                                                    :prefill (expt 2 16)
                                                    :profile ,profile)
                :function 'cl-bench.hash:bench-setget
                :runs 8)))
  (defb htable-equalp-numbers/average :average)
  (defb htable-equalp-numbers/typical :typical)
  (defb htable-equalp-numbers/dyadic :dyadic)
  (defb htable-equalp-numbers/collide :collide)
  (defb htable-equalp-numbers/beyond :beyond-collision)
  (defb htable-equalp-numbers/fixnum :fixnum)
  (defb htable-equalp-numbers/bignum :bignum)
  (defb htable-equalp-numbers/ratio :ratio)
  (defb htable-equalp-numbers/float :float)
  (defb htable-equalp-numbers/single :single)
  (defb htable-equalp-numbers/double :double)
  (defb htable-equalp-numbers/petite :petite)
  (defb htable-equalp-numbers/cfloat :complex-float)
  (defb htable-equalp-numbers/cratio :complex-ratio))

(defun setup-mixbag (&key (table-size 300)
                          (n-keys (expt 2 14))
                          (prefill 0))
  (setq *table* (make-hash-table :test 'equalp :size table-size))
  (setq *value* (random 89))
  (setq *keys*
        (loop repeat n-keys
              for key = (ecase (random 5)
                          (0 (random most-positive-fixnum))
                          (1 (random 33.2))
                          (2 (char "0123456789" (random 10)))
                          (3 (vector 1 "x" #\8 (random 3.4)))
                          (4 (string "jd was here \o/")))
              collect key
              do (unless (zerop prefill)
                   (decf prefill)
                   (setf (gethash key *table*) *value*)))))

(defun setup-string (&key (table-size 300)
                          (n-keys (expt 2 16))
                          (prefill 0)
                          (string-length 32)
                          (charset-length (length +alphanumeric+))
                          (anti-adaptive-p nil))
  (setq *table* (make-hash-table :test 'equal :size table-size))
  (setq *value* (random 42))
  (setq *keys*
        (loop repeat n-keys
              for key = (if anti-adaptive-p
                            (random-string-non-adaptive string-length n-keys)
                            (random-string string-length charset-length))
              collect key
              do (unless (zerop prefill)
                   (decf prefill)
                   (setf (gethash key *table*) *value*)))))

(defun setup-fixnum (&key (table-size 300)
                          (n-keys (expt 2 20))
                          (prefill 0)
                          (max-value most-positive-fixnum))
  (setq *table* (make-hash-table :test 'eql :size table-size))
  (setq *value* (random 89))
  (setq *keys*
        (loop repeat n-keys
              for key = (random max-value)
              collect key
              do (unless (zerop prefill)
                   (decf prefill)
                   (setf (gethash key *table*) *value*)))))

;;; This test excercises insert, map, get and upsert.
(defun bench-htable ()
  (let ((table *table*)
        (value *value*))
    (loop for i from 0
          for key in *keys*
          do (setf (gethash key table) (+ value i)))
    (maphash (lambda (key value)
               (incf (gethash key table) value))
             table)))

;;; We don't test mapping, only set.
(defun bench-setget ()
  (let ((table *table*)
        (value *value*))
    (loop for i from 0
          for key in *keys*
          do (setf (gethash key table) (+ value i)))))

;;; This test excercises alternating insert and remove.
(defun bench-setrem ()
  (let ((table *table*)
        (value *value*))
    (loop for i from 0 by 4
          for (k1 k2 k3 k4) on *keys* by #'cddddr
          do (setf (gethash k1 table) (+ value i))
             (setf (gethash k2 table) (+ value i))
             (setf (gethash k3 table) (+ value i))
             (setf (gethash k4 table) (+ value i))
             (remhash k1 table)
             (remhash k2 table)
             (remhash k3 table)
             (remhash k4 table))))

(defun bench-sxhash ()
  (let ((table *table*)
        (value *value*))
    (loop for i from 0
          for key in *keys*
          do (setf value (logxor value (sxhash key))))
    value))

;; EOF
