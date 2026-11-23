(defun controlled-add (a b) (+ a b))
(defun unboxed-add (a b)
  (declare (double-float a b) (optimize (speed 3) (debug 0)))
  (+ a b))
(defun unboxed-divide (a b)
  (declare (double-float a b) (optimize (speed 3) (debug 0)))
  (/ a b))
(defun unboxed-reciprocal (a)
  (declare (double-float a) (optimize (speed 3) (debug 0)))
  (/ a))
(defun reciprocal-of-fixnum (n)
  (declare (fixnum n) (optimize (speed 3) (debug 0)))
  (/ (float n 0d0)))
(assert (= (unboxed-reciprocal 4d0) (reciprocal-of-fixnum 4) 0.25d0))
(assert (= (reciprocal-of-fixnum -4) -0.25d0))
(assert (handler-case (progn (reciprocal-of-fixnum 0) nil) (division-by-zero () t)))
(assert (kiln.sys:float-infinity-p (kiln.sys:with-float-traps-masked t
                                    (reciprocal-of-fixnum 0))))
(let ((integer -3)
      (ratio (/ 2 7)))
  (declare (notinline + /))
  (kiln.sys:with-rounding-mode :positive
    (assert (= -19/7 (+ integer ratio) (+ ratio integer)))
    (assert (= -21/2 (/ integer ratio)))
    (assert (eql 0 (/ 0 ratio)))))
(assert (= #x3fb999999999999a (kiln.sys:double-float-bits (unboxed-reciprocal 10d0))))
(assert (= #x3fb9999999999999
           (kiln.sys:double-float-bits
            (kiln.sys:with-rounding-mode :negative (reciprocal-of-fixnum 10)))))
(assert (handler-case (progn (unboxed-reciprocal -0d0) nil) (division-by-zero () t)))
(assert (minusp (float-sign (kiln.sys:with-float-traps-masked (:divide-by-zero)
                             (unboxed-reciprocal -0d0)))))
(dolist (function (list #'controlled-add #'unboxed-add))
  (assert (= 4.500000000000001d0 (kiln.sys:with-rounding-mode :positive (funcall function 3.2d0 1.3d0))))
  (assert (= 4.5d0 (kiln.sys:with-rounding-mode :negative (funcall function 3.2d0 1.3d0))))
  (assert (= 4.5d0 (kiln.sys:with-rounding-mode :zero (funcall function 3.2d0 1.3d0))))
  (assert (= 4.5d0 (kiln.sys:with-rounding-mode :nearest (funcall function 3.2d0 1.3d0)))))
(dolist (function (list #'/ #'unboxed-divide))
  (assert (kiln.sys:float-infinity-p
           (kiln.sys:with-float-traps-masked (:divide-by-zero) (funcall function 1d0 0d0))))
  (assert (minusp (float-sign (kiln.sys:with-float-traps-masked (:divide-by-zero)
                                (funcall function 1d0 -0d0)))))
  (assert (kiln.sys:float-nan-p
           (kiln.sys:with-float-traps-masked (:invalid) (funcall function 0d0 0d0))))
  (assert (handler-case (progn (funcall function 1d0 0d0) nil) (division-by-zero () t)))
  (assert (handler-case (progn (funcall function 0d0 0d0) nil) (floating-point-invalid-operation () t))))
(assert (handler-case (kiln.sys:with-float-traps-masked t (/ 1 0)) (division-by-zero () t)))
(catch 'restore
  (kiln.sys:with-rounding-mode :positive
    (kiln.sys:with-float-traps-masked t
      (throw 'restore nil))))
(assert (= 4.5d0 (controlled-add 3.2d0 1.3d0)))
(assert (handler-case (progn (unboxed-divide 1d0 0d0) nil) (division-by-zero () t)))
(defun returned-double-product (initial count)
  (declare (double-float initial) (fixnum count))
  (dotimes (index count initial)
    (setf initial (* initial 2d0))))
(let ((seed (kiln.sys:bits-double-float #x8000000000000000)))
  (assert (eq seed (returned-double-product seed 0)))
  (assert (= #x8000000000000000
             (kiln.sys:double-float-bits (returned-double-product seed 4)))))
(assert (= 48d0 (returned-double-product 3d0 4)))
(defun loop-reciprocal-of-positive-fixnum (n count)
  (declare (type (integer 1 36028797018963968) n) (fixnum count))
  (let ((result 0d0))
    (dotimes (index count result)
      (setf result (/ (float n 0d0))))))
(let ((n (1+ (ash 1 54))))
  (declare (notinline float /))
  (assert (= (loop-reciprocal-of-positive-fixnum n 2) (/ (float n 0d0))))
  (kiln.sys:with-rounding-mode :positive
    (assert (= (loop-reciprocal-of-positive-fixnum n 2) (/ (float n 0d0)))))
  (kiln.sys:with-rounding-mode :negative
    (assert (= (loop-reciprocal-of-positive-fixnum n 2) (/ (float n 0d0))))))
(defun observed-double-product (initial count observer)
  (declare (double-float initial) (fixnum count))
  (dotimes (index count initial)
    (setf initial (* initial 2d0))
    (funcall observer initial)))
(let ((last nil))
  (assert (eq (observed-double-product 3d0 4 (lambda (value) (setf last value)))
              last)))
(kiln.sys:with-rounding-mode :positive
  (assert (= 4.500000000000001d0 (kiln.sys:with-rounding-mode :negative
                                  (kiln.sys:with-rounding-mode :positive (controlled-add 3.2d0 1.3d0)))))
  (assert (= 4.500000000000001d0 (controlled-add 3.2d0 1.3d0))))
(dolist (add (list #'controlled-add #'unboxed-add))
  (assert (= #x8000000000000000
             (kiln.sys:double-float-bits (kiln.sys:with-rounding-mode :negative (funcall add 1d0 -1d0)))))
  (assert (handler-case (progn (funcall add most-positive-double-float most-positive-double-float) nil)
            (floating-point-overflow () t)))
  (assert (kiln.sys:float-infinity-p
           (kiln.sys:with-float-traps-masked (:overflow)
             (funcall add most-positive-double-float most-positive-double-float))))
  (assert (= most-positive-double-float
             (kiln.sys:with-float-traps-masked (:overflow)
               (kiln.sys:with-rounding-mode :zero (funcall add most-positive-double-float most-positive-double-float))))))
(assert (= least-positive-double-float
           (kiln.sys:with-rounding-mode :positive (/ least-positive-double-float 2d0))))
(assert (zerop (kiln.sys:with-rounding-mode :nearest (/ least-positive-double-float 2d0))))
(assert (= (- least-positive-double-float)
           (kiln.sys:with-rounding-mode :negative (/ (- least-positive-double-float) 2d0))))
(assert (= 1.0000001f0
           (kiln.sys:with-rounding-mode :nearest (float (+ 1 (expt 2 -24) (expt 2 -80)) 1f0))))
(assert (= 1f0 (kiln.sys:with-rounding-mode :nearest (+ 1f0 (+ (expt 2 -24) (expt 2 -80))))))
(assert (= 1.0000001f0 (kiln.sys:with-rounding-mode :positive (coerce (+ 1 (expt 2 -25)) 'single-float))))
(assert (kiln.sys:float-infinity-p (kiln.sys:with-float-traps-masked (:overflow) (exp 1000d0))))
(catch 'other-stack
  (kiln.sys:with-rounding-mode :positive
    (kiln.sys:%call-on-new-stack
     (lambda (ignored) (declare (ignore ignored))
       (assert (= 4.500000000000001d0 (unboxed-add 3.2d0 1.3d0)))
       (kiln.sys:%gc)
       (throw 'other-stack nil)) nil)))
(assert (= 4.5d0 (unboxed-add 3.2d0 1.3d0)))
(assert (= #x3fb999999999999a (kiln.sys:double-float-bits
                              (kiln.sys:with-rounding-mode :nearest (unboxed-divide 1d0 10d0)))))
(assert (= #x3fb999999999999a (kiln.sys:double-float-bits
                              (kiln.sys:with-rounding-mode :positive (unboxed-divide 1d0 10d0)))))
(assert (= #x3fb9999999999999 (kiln.sys:double-float-bits
                              (kiln.sys:with-rounding-mode :negative (unboxed-divide 1d0 10d0)))))
(assert (= #x3fb9999999999999 (kiln.sys:double-float-bits
                              (kiln.sys:with-rounding-mode :zero (unboxed-divide 1d0 10d0)))))
(defun unboxed-fold (a b c)
  (declare (double-float a b c) (optimize (speed 3) (safety 1) (debug 0)))
  (values (+ a b c) (- a b c) (* a b c) (/ a b c)))

(assert (equal '(9d0 3d0 12d0 3d0) (multiple-value-list (unboxed-fold 6d0 2d0 1d0))))
(assert (= 0d0 (unboxed-fold 1d0 (scale-float 1d0 54) (- (scale-float 1d0 54)))))
(assert (= 1.0000000000000004d0
           (kiln.sys:with-rounding-mode :positive
             (unboxed-fold 1d0 (scale-float 1d0 -53) (scale-float 1d0 -53)))))
(assert (handler-case (unboxed-fold most-positive-double-float most-positive-double-float 1d0)
          (floating-point-overflow () t)))
(assert (handler-case (unboxed-fold most-positive-double-float 0d0 most-positive-double-float)
          (floating-point-overflow () t)))
(defun single-arithmetic (a b)
  (declare (single-float a b) (optimize (speed 3) (safety 1)))
  (values (+ a b) (- a b) (* a b) (/ a b)))

(assert (equal '(9f0 3f0 18f0 2f0) (multiple-value-list (single-arithmetic 6f0 3f0))))
(assert (eql 1f0 (single-arithmetic 1f0 (scale-float 1f0 -24))))
(assert (eql 1.0000001f0
             (kiln.sys:with-rounding-mode :positive
               (single-arithmetic 1f0 (scale-float 1f0 -24)))))
(assert (eql -0f0 (nth-value 2 (single-arithmetic -0f0 2f0))))
(assert (handler-case (single-arithmetic most-positive-single-float most-positive-single-float)
          (floating-point-overflow () t)))
(assert (handler-case (single-arithmetic 1f0 0f0) (division-by-zero () t)))
(assert (kiln.sys:float-nan-p
         (kiln.sys:with-float-traps-masked (:invalid)
           (nth-value 3 (single-arithmetic 0f0 0f0)))))

(defun single-scalar-across-gc (left right)
  (declare (single-float left right) (optimize (speed 3) (safety 3)))
  (let ((product (* left right)))
    (kiln.sys:%gc)
    (+ product right)))

(assert (eql 9f0 (single-scalar-across-gc 2f0 3f0)))
(assert (kiln.sys:float-infinity-p
         (kiln.sys:with-float-traps-masked (:overflow)
           (single-scalar-across-gc most-positive-single-float 2f0))))

(defun add-single-pair-in-loop (a b count)
  (declare (single-float a b) (fixnum count) (optimize (speed 3) (safety 3)))
  (dotimes (i count a)
    (setq a (+ (+ a b) b))))

(defun add-single-pair-with-hook (a b count before-second)
  (declare (single-float a b) (fixnum count) (optimize (speed 3) (safety 3)))
  (dotimes (i count a)
    (setq a (+ a b))
    (funcall before-second)
    (setq a (+ a b))))

(let ((half-ulp (scale-float 1f0 -24)))
  (assert (eql 1f0 (add-single-pair-in-loop 1f0 half-ulp 1)))
  (assert (eql 1.0000002f0
               (kiln.sys:with-rounding-mode :positive
                 (add-single-pair-in-loop 1f0 half-ulp 1))))
  (let ((kiln.kernel::*float-control-active* nil)
        (kiln.kernel::*float-rounding-mode* :nearest))
    (assert (eql 1.0000001f0
                 (add-single-pair-with-hook
                  1f0 half-ulp 1
                  (lambda ()
                    (setq kiln.kernel::*float-control-active* t
                          kiln.kernel::*float-rounding-mode* :positive)))))))

(defun add-single-array-in-loop (value increments index count)
  (declare (single-float value) ((simple-array single-float (1)) increments)
           (fixnum index count) (optimize (speed 3) (safety 3)))
  (dotimes (i count value)
    (setq value (+ value (aref increments 0))
          value (+ value (aref increments index)))))

(let ((increments (make-array 1 :element-type 'single-float
                                :initial-element (scale-float 1f0 -24))))
  (assert (eql 1f0 (add-single-array-in-loop 1f0 increments 0 1)))
  (assert (eql 1.0000002f0
               (kiln.sys:with-rounding-mode :positive
                 (add-single-array-in-loop 1f0 increments 0 1))))
  (assert (handler-case (progn (add-single-array-in-loop 1f0 increments 1 1) nil)
            (type-error () t))))

(defun double-add-in-loop (value increment count)
  (declare (double-float value increment) (fixnum count)
           (optimize (speed 3) (safety 3)))
  (dotimes (i count value)
    (setq value (+ value increment))))

(assert (= 4d0 (double-add-in-loop 1d0 1d0 3)))
(assert (= 1.0000000000000004d0
           (kiln.sys:with-rounding-mode :positive
             (double-add-in-loop 1d0 (scale-float 1d0 -53) 2))))
(assert (handler-case
            (progn (double-add-in-loop most-positive-double-float most-positive-double-float 2) nil)
          (floating-point-overflow () t)))

(defun double-chain-in-loop (value increment count)
  (declare (double-float value increment) (fixnum count)
           (optimize (speed 3) (safety 3)))
  (dotimes (i count value)
    (setq value (+ (+ value increment increment) increment))))

(let ((half-ulp (scale-float 1d0 -53)))
  (assert (= 1d0 (double-chain-in-loop 1d0 half-ulp 1)))
  (assert (= (+ 1d0 (scale-float 3d0 -52))
             (kiln.sys:with-rounding-mode :positive
               (double-chain-in-loop 1d0 half-ulp 1)))))

(defun fixnum-to-double (n)
  (declare (fixnum n) (optimize (speed 3) (safety 3)))
  (float n 0d0))

(defun multiply-converted-fixnums (a b)
  (declare (fixnum a b) (optimize (speed 3) (safety 3)))
  (* (float a 0d0) (float b 0d0)))

(defun reference-converted-product (a b)
  (declare (notinline float *))
  (* (float a 0d0) (float b 0d0)))

(dolist (a (list most-negative-fixnum -9007199254740993 0 most-positive-fixnum))
  (dolist (b (list most-negative-fixnum 3 most-positive-fixnum))
    (assert (eql (multiply-converted-fixnums a b) (reference-converted-product a b)))
    (kiln.sys:with-rounding-mode :positive
      (assert (eql (multiply-converted-fixnums a b) (reference-converted-product a b))))))

(defun convert-and-add-in-loop (n count)
  (declare (fixnum n count) (optimize (speed 3) (safety 3)))
  (let ((value 0d0))
    (dotimes (i count value)
      (setf value (+ (float n 0d0) 1d0)))))

(assert (= 43d0 (convert-and-add-in-loop 42 2)))
(assert (= 9007199254740992d0 (convert-and-add-in-loop 9007199254740993 2)))
(kiln.sys:with-rounding-mode :positive
  (assert (= 9007199254740994d0 (convert-and-add-in-loop 9007199254740992 2)))
  (assert (= 9007199254740996d0 (convert-and-add-in-loop 9007199254740993 2))))

(defun bounded-fixnum-to-double (n sample)
  (declare (type (integer -65536 65536) n) (optimize (speed 3) (safety 3)))
  (float n (the double-float (funcall sample))))

(dolist (n (list most-negative-fixnum most-positive-fixnum (- (1+ (ash 1 53)))
                 (- (ash 1 53)) -1 0 1 (ash 1 53) (1+ (ash 1 53)) (+ (ash 1 53) 3)))
  (locally (declare (notinline float))
    (assert (eql (float n 0d0) (fixnum-to-double n)))
    (kiln.sys:with-rounding-mode :nearest
      (assert (eql (float n 0d0) (fixnum-to-double n))))
    (kiln.sys:with-rounding-mode :positive
      (assert (eql (float n 0d0) (fixnum-to-double n))))
    (kiln.sys:with-rounding-mode :negative
      (assert (eql (float n 0d0) (fixnum-to-double n))))
    (kiln.sys:with-rounding-mode :zero
      (assert (eql (float n 0d0) (fixnum-to-double n))))))
(defun unknown-to-double (n)
  (declare (optimize (speed 3) (safety 3)))
  (float n 0d0))
(assert (eql 4d0 (unknown-to-double 4)))
(assert (eql (scale-float 1d0 70) (unknown-to-double (ash 1 70))))
(assert (eql 0.5d0 (unknown-to-double 1/2)))
(assert (eql 2d0 (unknown-to-double 2f0)))
(assert (handler-case (progn (unknown-to-double :invalid) nil) (type-error () t)))
(let ((boundary (ash 1 53)))
  (kiln.sys:with-rounding-mode :positive
    (assert (eql 9007199254740992d0 (unknown-to-double boundary)))
    (assert (eql 9007199254740994d0 (unknown-to-double (1+ boundary)))))
  (kiln.sys:with-rounding-mode :negative
    (assert (eql -9007199254740992d0 (unknown-to-double (- boundary))))
    (assert (eql -9007199254740994d0 (unknown-to-double (1- (- boundary)))))))
(let ((calls 0))
  (kiln.sys:with-rounding-mode :positive
    (assert (eql -32768d0 (bounded-fixnum-to-double -32768 (lambda () (incf calls) 4d0)))))
  (assert (= calls 1)))
(dolist (case '((3.5d0 3 0.5d0) (-3.5d0 -3 -0.5d0)
                (-0d0 0 -0d0) (-0.5d0 0 -0.5d0)
                (4611686018427387904d0 4611686018427387904 0d0)
                (-4611686018427387904d0 -4611686018427387904 0d0)))
  (destructuring-bind (input quotient remainder) case
    (assert (equal (multiple-value-list (truncate input)) (list quotient remainder)))
    (assert (equal (multiple-value-list (ftruncate input)) (list (float quotient 0d0) remainder)))))

(defun compare-random-float-sequences ()
  (dolist (limit (list 1f0 1d0 3.5d0
                       (- 1d0 (scale-float 1d0 -53))
                       (+ 1d0 (scale-float 1d0 -52))
                       (* 16f0 least-positive-single-float)
                       (* 16d0 least-positive-double-float)))
    (let ((fast (make-random-state nil))
          (reference (make-random-state nil)))
      (dotimes (i 20)
        (assert (eql (random limit fast)
                     (loop for value = (* limit
                                          (float (/ (kiln.kernel::random-bits 53 reference) (ash 1 53))
                                                 limit))
                           when (< value limit) return value)))))))

(compare-random-float-sequences)
(assert (eql 0d0 (kiln.sys:%primop :double-fraction-53 0)))
(assert (eql (- 1d0 (scale-float 1d0 -53))
             (kiln.sys:%primop :double-fraction-53 (1- (ash 1 53)))))
(kiln.sys:with-rounding-mode :positive (compare-random-float-sequences))
(kiln.sys:with-rounding-mode :negative (compare-random-float-sequences))

(defun literal-unit-random (&optional (state *random-state*))
  (declare (optimize (speed 3)))
  (values (random 1d0) (random 1d0 state)))

(let ((*random-state* (make-random-state))
      (reference (make-random-state)))
  (dotimes (i 10)
    (multiple-value-bind (implicit explicit) (literal-unit-random)
      (locally (declare (notinline random))
        (assert (eql implicit (random 1d0 reference)))
        (assert (eql explicit (random 1d0 reference)))))))

(let ((*random-state* nil))
  (makunbound '*random-state*)
  (assert (handler-case (progn (literal-unit-random (make-random-state t)) nil)
            (unbound-variable (condition)
              (eq '*random-state* (cell-error-name condition))))))

(print :float-controls)

(defun multiply-add-array (n x y initial)
  (declare (fixnum n) (double-float x y initial) (optimize (speed 3) (debug 0)))
  (let ((result (make-array n :element-type 'double-float :initial-element initial)))
    (dotimes (i n result)
      (incf (aref result i) (* x y)))))

(assert (equalp #(7d0 7d0) (multiply-add-array 2 2d0 3d0 1d0)))
(assert (handler-case (progn (multiply-add-array 2 most-positive-double-float 2d0 0d0) nil)
          (floating-point-overflow (condition) (eq '* (arithmetic-error-operation condition)))))
(assert (handler-case (progn (multiply-add-array 2 most-positive-double-float 1d0
                                                 most-positive-double-float) nil)
          (floating-point-overflow (condition) (eq '+ (arithmetic-error-operation condition)))))
(assert (equalp #(1.0000000000000002d0 1.0000000000000002d0)
                (kiln.sys:with-rounding-mode :positive
                  (multiply-add-array 2 (scale-float 1d0 -53) 1d0 1d0))))
