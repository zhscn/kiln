;; Sala's representation combines Gudermannian(w) with
;; 2*sum(atan(sinh(w)/cosh(n*c))). These inputs exercise cancellation
;; between the initial imaginary component and the series corrections.
(defun sala-amplitude (w c)
  (let* ((x (realpart w)) (y (imagpart w))
         (sum (complex (atan (sinh x) (cos y))
                       (atanh (/ (sin y) (cosh x)))))
         (sinh-w (sinh w)))
    (do* ((n 1 (1+ n))
          (term (* 2 (atan (/ sinh-w (cosh (* n c)))))
                (* 2 (atan (/ sinh-w (cosh (* n c)))))))
         ((<= (abs term) (* (abs sum) double-float-epsilon)) sum)
      (incf sum term))))
(let ((result (sala-amplitude #c(1.2739475541161045d0 2.5478951082322094d0)
                              #c(2.8643486740309885d0 -3.141592653589793d0))))
  (assert (< (abs (- result #c(2.332625972754849d0 0.0716954393741584d0))) 9.3919d-16)))
(print :jacobi-am-sala)
