;;; Decoding floats (CLHS 12.2) and ~F rounding a tie, which compares the
;;; decimal digits with the exact binary value (Invistra, base 2). Not
;;; (format nil "~,1f" 0.05f0): Invistra makes "0.0" in SBCL too.
(dolist (x (list 0d0 -0d0 0f0 1d0 1.5f0 -6d0 0.1d0 1d300 4.9406564584124654d-324
                 1.4012985f-45 3.4028235f38 2.2250738585072014d-308))
  (print (list x (multiple-value-list (integer-decode-float x))
               (multiple-value-list (decode-float x))
               (float-precision x) (float-digits x) (float-radix x)
               (float-sign x) (float-sign x 3d0))))
(print (list (scale-float 1.5d0 3) (scale-float 1d0 -1074) (scale-float 1d-300 600)
             (scale-float 1.5f0 -2)))
(print (list (format nil "~,1f" 0.25d0) (format nil "~,1f" 0.35d0) (format nil "~,0f" 2.5d0)
             (format nil "~,2f" 1.005d0) (format nil "~,1f" 1234.45d0)
             (format nil "~10,1f" 1234.25d0)))
