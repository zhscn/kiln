;;; Pairs consumed through local exits inside an integer checksum loop.
(declaim (notinline benchmark-scalar-cons-block))
(defun benchmark-scalar-cons-block (count)
  (declare (type (integer 0 1048576) count))
  (let ((checksum 0))
    (declare (fixnum checksum))
    (dotimes (index count checksum)
      (setq checksum
            (logxor checksum
                    (let ((pair (cons index (1+ index))))
                      (block done (return-from done (+ (car pair) (cdr pair))))))))))
(let ((value (benchmark-scalar-cons-block 1000000)))
  (unless (zerop value) (error "Unexpected scalar-cons-block result: ~S" value))
  (print value))
