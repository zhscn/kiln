;;; Branches update the same integer state through different local exits.
(declaim (notinline benchmark-block-state))
(defun benchmark-block-state (count flag)
  (declare (type (integer 0 1048576) count))
  (let ((checksum 0))
    (dotimes (index count checksum)
      (block done
        (when flag
          (setq checksum (logxor checksum (1+ index)))
          (return-from done))
        (setq checksum (logxor checksum (1+ index)))))))
(let ((value (benchmark-block-state 1000000 t)))
  (unless (= value 1000000) (error "Unexpected block-state result: ~S" value))
  (print value))
