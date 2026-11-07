;;; Complex numbers (CLHS 12.1.5): canonical construction, arithmetic and
;;; contagion, comparison, EQL and hashing, types and classes, the
;;; elementary functions, reading and printing.

(defun show (x) (write-line (prin1-to-string x)))

;; Construction and canonicalization.
(show (list (complex 1 2) (complex 1 0) (complex 1.0) (complex 1 0.0) (complex 1/2 -3)
            (complex 1.0 2d0) #c(3 4) #c(1.5 0) #c(1 0)))
(show (list (realpart #c(1 2)) (imagpart #c(1 2)) (realpart 5) (imagpart 5) (imagpart 2.5)
            (conjugate #c(1 2)) (conjugate 3)))

;; Arithmetic.
(let ((a #c(1 2)) (b #c(3 -4)))
  (show (list (+ a b) (- a b) (* a b) (/ a b) (+ a 1) (* 2 a) (- a) (/ a 2) (/ 1 a)
              (+ a 0.5) (* a 1d0) (+ a (- a)) (* #c(0 1) #c(0 1)) (1+ a) (expt a 3)
              (expt a -1) (expt a 0))))
(show (list (= #c(1 2) #c(1 2)) (= #c(1 2) #c(1.0 2.0)) (= #c(1 2) 1) (/= #c(1 2) #c(2 1))
            (zerop #c(0.0 0.0)) (zerop #c(1 2)) (= 1 (complex 1 0))))
(show (handler-case (< #c(1 2) 3) (type-error () 'type-error)))
(show (handler-case (/ #c(1 2) 0) (division-by-zero () 'division-by-zero)))

;; Absolute value, phase, signum.
(show (list (abs #c(3 4)) (abs #c(3.0d0 4.0d0)) (abs #c(-3.0 -4.0)) (phase #c(0 1)) (phase -1)
            (signum #c(3 4)) (signum -2.5) (signum 0) (cis 0)))

;; EQL, EQUAL, EQUALP, hash tables.
(show (list (eql #c(1 2) (complex 1 2)) (eql #c(1.0 2.0) #c(1 2)) (equal #c(1 2) #c(1 2))
            (equalp #c(1 2) #c(1.0 2.0)) (eql #c(1.0 2.0) (complex 1.0 2.0))))
(let ((h (make-hash-table)))
  (setf (gethash (complex 1 2) h) 'a (gethash (complex 1.0 2.0) h) 'b)
  (show (list (gethash #c(1 2) h) (gethash #c(1.0 2.0) h) (hash-table-count h))))

;; Types and classes.
(show (list (complexp #c(1 2)) (complexp 1) (numberp #c(1 2)) (realp #c(1 2))
            (typep #c(1 2) 'complex) (typep #c(1 2) 'number) (typep #c(1 2) '(complex rational))
            (typep #c(1.0 2.0) '(complex single-float)) (typep #c(1.0 2.0) '(complex double-float))
            (typep #c(1 2) '(complex float)) (type-of #c(1d0 2d0)) (type-of #c(1 2))
            (class-name (class-of #c(1 2))) (subtypep 'complex 'number)))
(defgeneric kind (x))
(defmethod kind ((x complex)) 'complex)
(defmethod kind ((x real)) 'real)
(show (list (kind #c(1 2)) (kind 1)))

;; Elementary functions.
(defun near (a b) (< (abs (- a b)) 1d-6))
(show (list (log -1) (imagpart -1d0) (expt 0 #c(1 1)) (sqrt -4) (sqrt -4d0) (sqrt #c(3 4)) (near (sqrt #c(0d0 2d0)) #c(1d0 1d0))
            (near (exp #c(0d0 1d0)) (complex (cos 1d0) (sin 1d0)))
            (near (log -1d0) (complex 0d0 pi)) (near (log #c(0d0 1d0)) (complex 0 (/ pi 2)))
            (near (expt #c(0d0 1d0) 2) -1) (near (expt -8d0 1/3) #c(1d0 1.7320508d0))
            (near (sin #c(1d0 1d0)) #c(1.2984575814159773d0 0.6349639147847361d0))
            (near (cos #c(1d0 1d0)) #c(0.8337300251311491d0 -0.9888977057628651d0))
            (near (asin 2d0) #c(1.5707963267948966d0 -1.3169578969248166d0))
            (near (asin -2d0) #c(-1.5707963267948966d0 1.3169578969248166d0))
            (near (acos -2d0) #c(3.141592653589793d0 -1.3169578969248166d0))
            (near (atanh 2d0) #c(0.5493061443340549d0 1.5707963267948966d0))
            (near (atanh -2d0) #c(-0.5493061443340549d0 1.5707963267948966d0))
            (near (asinh #c(0d0 2d0)) #c(1.3169578969248166d0 1.5707963267948966d0))
            (near (acosh 0.5d0) #c(0.0d0 1.0471975511965979d0))
            (near (atan #c(1d0 2d0)) #c(1.3389725222944935d0 0.40235947810852507d0))
            (near (expt #c(1 2) 1/2) #c(1.2720196 0.78615147))
            (near (atan #c(0d0 0.5d0)) #c(0d0 0.5493061443340549d0))
            (near (sinh 1d0) 1.1752011936438014d0) (near (cosh 1d0) 1.5430806348152437d0)
            (near (tanh 1d0) 0.7615941559557649d0) (near (asinh 1d0) 0.881373587019543d0)
            (near (acosh 2d0) 1.3169578969248166d0) (near (atanh 0.5d0) 0.5493061443340549d0)
            (near (acos 0.5d0) (/ pi 3)) (near (asin 0.5d0) (/ pi 6))))

;; Reading and printing.
(show (list (read-from-string "#C(1 2)") (read-from-string "#c(1.5 -2.5)")
            (read-from-string "#C(2 0)") (format nil "~A ~S" #c(1 2) #c(1d0 -1d0))))

;; The mandelbrot loop of cl-bench.
(defun mset-level (c)
  (loop :for z = #c(0 0) :then (+ (* z z) c)
        :for iter :from 1 :to 300
        :until (> (abs z) 4.0)
        :finally (return iter)))
(show (let ((sum 0))
        (dotimes (i 100 sum)
          (incf sum (mset-level (complex 0.0001d0 (/ i 100 0.25d0)))))))

;; Across a GC.
(let ((l (loop for i below 1000 collect (complex i (1+ i)))))
  (kiln.sys:%gc)
  (show (reduce #'+ l)))
