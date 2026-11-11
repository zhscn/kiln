;;; Field-only pairs feed a retained local helper through its lexical scope.
(declaim (notinline benchmark-cons-local-call))
(defun benchmark-cons-local-call (count)
  (declare (type (integer 0 1048576) count))
  (let ((checksum 0))
    (declare (fixnum checksum))
    (dotimes (index count checksum)
      (setq checksum
            (logxor checksum
                    (let ((pair (cons index (1+ index))))
                      (flet ((finish (left right) (+ left right)))
                        (declare (notinline finish))
                        (finish (car pair) (cdr pair)))))))))
(let ((value (benchmark-cons-local-call 1000000)))
  (unless (zerop value) (error "Unexpected cons-local-call result: ~S" value))
  (print value))
