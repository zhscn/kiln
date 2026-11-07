;;;; The part of Quaviver's interface that the printer modules use:
;;;; FLOAT-TRIPLE, WRITE-DIGITS and COUNT-DIGITS. The
;;;; shortest decimal representation of a float comes from the runtime
;;;; (kiln_rt_float_decimal); Quaviver itself (Schubfach etc.) can replace
;;;; this file later.

(cl:defpackage #:quaviver
  (:use #:common-lisp)
  (:export #:float-triple #:write-digits))

(cl:defpackage #:quaviver.math
  (:use #:common-lisp)
  (:export #:count-digits))

(in-package #:quaviver)

(defun float-triple (client base value)
  "Three values: the significand, the exponent and the sign of VALUE
(significand * BASE^exponent): for BASE 10 its shortest decimal
representation, or :INFINITY or :QUIET-NAN as the exponent; for BASE 2
the exact one, INTEGER-DECODE-FLOAT's (Invistra's ~F rounds a tie with
it)."
  (declare (ignore client))
  (when (eql base 2)
    (return-from float-triple (integer-decode-float value)))
  (unless (eql base 10)
    (error "Only bases 2 and 10 are supported: ~s" base))
  (let ((significand (kiln.sys:%primop :float-decimal value 0))
        (exponent (kiln.sys:%primop :float-decimal value 1))
        (sign (kiln.sys:%primop :float-decimal value 2)))
    (values significand
            (case exponent
              (10000 :infinity)
              (10001 :quiet-nan)
              (t exponent))
            sign)))

(defun quaviver.math:count-digits (base value)
  (if (zerop value)
      1
      (do ((n 0 (+ n 1))
           (v value (floor v base)))
          ((zerop v) n))))

(defun group-marker-p (index spec)
  ;; Quaviver's: is a group marker due before the digit at INDEX (counted
  ;; from the fractional position)? SPEC is a vector of group sizes.
  (cond ((zerop index)
         nil)
        ((plusp index)
         (prog ((gid (position-if #'plusp spec)))
            (unless gid
              (return nil))
          next
            (cond ((< (1+ gid) (length spec))
                   (decf index (aref spec gid))
                   (incf gid)
                   (go next))
                  (t
                   (setf index (mod index (aref spec gid)))))
            (return (zerop index))))
        (t
         (prog ((gid (position-if #'minusp spec :from-end t)))
            (unless gid
              (return nil))
          next
            (cond ((plusp gid)
                   (decf index (aref spec gid))
                   (decf gid)
                   (go next))
                  (t
                   (setf index (mod index (aref spec gid)))))
            (return (zerop index))))))

(defun write-digits (base value stream
                     &key fractional-position fractional-marker
                          digit-grouping group-marker
                          (leading-zeros 0) (digit-char 'digit-char))
  "Writes the digits of the nonnegative integer VALUE in BASE to STREAM,
as Quaviver's WRITE-DIGITS: LEADING-ZEROS zeros first, the
FRACTIONAL-MARKER after FRACTIONAL-POSITION digits (padding with zeros on
either side), and GROUP-MARKER between the groups of DIGIT-GROUPING."
  (let* ((leading-zeros (or leading-zeros 0))
         (digits (let ((ds '()))
                   (if (zerop value)
                       (push 0 ds)
                       (do ((v value (floor v base)))
                           ((zerop v))
                         (push (mod v base) ds)))
                   ds))
         (power (length digits))
         (fractional-position (or fractional-position power))
         (pos (- (min fractional-position 0) leading-zeros))
         (written nil)
         (zero-char (funcall digit-char 0 base)))
    (flet ((write-digit (ch)
             (when (and written digit-grouping group-marker
                        (group-marker-p (- fractional-position pos) digit-grouping))
               (write-char group-marker stream))
             (write-char ch stream)
             (incf pos)
             (setf written t)
             (when (and fractional-marker (= pos fractional-position))
               (write-char fractional-marker stream))))
      (when (and fractional-marker
                 (not (plusp fractional-position))
                 (zerop leading-zeros))
        (write-char fractional-marker stream))
      (dotimes (i leading-zeros)
        (write-digit zero-char))
      (loop while (minusp pos)
            do (write-digit zero-char))
      (dolist (d digits)
        (write-digit (funcall digit-char d base)))
      (loop while (< pos fractional-position)
            do (write-digit zero-char))))
  value)
