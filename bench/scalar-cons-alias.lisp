;;; Local aliases of mutable pairs inside an integer checksum loop.
(declaim (notinline benchmark-scalar-cons-alias))
(defun benchmark-scalar-cons-alias (count)
  (declare (type (integer 0 1048576) count))
  (let ((checksum 0))
    (declare (fixnum checksum))
    (dotimes (index count checksum)
      (setq checksum
            (logxor checksum
                    (let ((pair (cons index (1+ index))))
                      (let ((alias pair))
                        (let ((next alias))
                          (rplaca next (cdr alias))
                          (rplacd pair index)
                          (+ (car alias) (cdr next))))))))))
(let ((value (benchmark-scalar-cons-alias 1000000)))
  (unless (zerop value) (error "Unexpected scalar-cons-alias result: ~S" value))
  (print value))
