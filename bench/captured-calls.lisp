;;; A shared mutable accumulator exposes closure and cell costs across two
;;; local call sites. Keep the outer function callable for isolated counters.
(declaim (notinline benchmark-captured-calls))
(defun benchmark-captured-calls (count)
  (declare (type (integer 0 1048576) count))
  (let ((checksum 0))
    (declare (fixnum checksum))
    (flet ((mix-value (value) (setq checksum (logxor checksum value))))
      (dotimes (index count checksum)
        (mix-value index)
        (mix-value (+ index 2))))))

(let ((checksum (benchmark-captured-calls 1048575)))
  (unless (= checksum 2097150) (error "Unexpected captured-call checksum: ~S" checksum))
  (print checksum))
