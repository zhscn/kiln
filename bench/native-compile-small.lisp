;;; Compile independent small functions; do not reuse the top-level cache.
;;; Report microseconds per compilation after warming the compiler.
(defparameter *native-small-definition* '(lambda (x) (+ x 1)))
(dotimes (i 16) (compile nil *native-small-definition*))
(let ((start (get-internal-run-time)) (sum 0) (count 200))
  (dotimes (i count)
    (incf sum (funcall (compile nil *native-small-definition*) i)))
  (unless (= sum 20100) (error "Incorrect compiled function result."))
  (format t "~,3F~%" (* 1000000d0 (/ (- (get-internal-run-time) start)
                                   internal-time-units-per-second count))))
