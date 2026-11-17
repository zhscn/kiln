(defun controlled-add (a b) (+ a b))
(defun unboxed-add (a b)
  (declare (double-float a b) (optimize (speed 3) (debug 0)))
  (+ a b))
(defun unboxed-divide (a b)
  (declare (double-float a b) (optimize (speed 3) (debug 0)))
  (/ a b))
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
(print :float-controls)
