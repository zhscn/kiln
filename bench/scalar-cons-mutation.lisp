;;; Mutable field-only pairs inside an integer checksum loop.
(declaim (notinline benchmark-scalar-cons-mutation))
(defun benchmark-scalar-cons-mutation (count)
  (declare (type (integer 0 1048576) count))
  (let ((checksum 0))
    (declare (fixnum checksum))
    (dotimes (index count checksum)
      (setq checksum
            (logxor checksum
                    (let ((pair (cons index (1+ index))))
                      (rplaca pair (cdr pair))
                      (rplacd pair index)
                      (+ (car pair) (cdr pair))))))))
(let ((value (benchmark-scalar-cons-mutation 1000000)))
  (unless (zerop value) (error "Unexpected scalar-cons-mutation result: ~S" value))
  (print value))
