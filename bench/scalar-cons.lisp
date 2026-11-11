;;; Field-only pairs inside an integer checksum loop.
(declaim (notinline benchmark-scalar-cons))
(defun benchmark-scalar-cons (count)
  (declare (type (integer 0 1048576) count))
  (let ((checksum 0))
    (declare (fixnum checksum))
    (dotimes (index count checksum)
      (setq checksum
            (logxor checksum
                    (let ((pair (cons index (1+ index))))
                      (+ (car pair) (cdr pair))))))))
(let ((value (benchmark-scalar-cons 1000000)))
  (unless (zerop value) (error "Unexpected scalar-cons result: ~S" value))
  (print value))
