;; Reference rounded from log((1+x)/(1-x))/2 at 70 decimal digits,
;; with x taken as the exact binary64 input.
(assert (= (atanh 0.2902613110736827d0) 0.29885159252037635d0))
(assert (= (atanh -0.2902613110736827d0) -0.29885159252037635d0))
(assert (= (atanh 1d-20) 1d-20))
(assert (= (float-sign (atanh -0d0)) -1d0))
(assert (typep (atanh 1/2) 'single-float))
(assert (typep (atanh 0.5d0) 'double-float))
(dolist (pair '((0.9827284275322304d0 2.371583614415883d0)
                (0.03531254506018124d0 0.035327234015308566d0)))
  (dolist (sign '(1d0 -1d0))
    (assert (= (atanh (* sign (first pair))) (* sign (second pair))))))
(print :real-atanh-rounding)
