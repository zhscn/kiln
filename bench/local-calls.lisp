;;; Two call sites share an undeclared helper argument. Keep the outer
;;; function callable so counters can isolate the loop from image startup.
(declaim (notinline benchmark-local-calls))
(defun benchmark-local-calls (count)
  (declare (type (integer 0 1048576) count))
  (flet ((mix-value (value) (+ value 1)))
    (let ((checksum 0))
      (declare (fixnum checksum))
      (dotimes (index count checksum)
        (setq checksum (logxor checksum (mix-value index)))
        (setq checksum (logxor checksum (mix-value (+ index 2))))))))

(let ((checksum (benchmark-local-calls 1048575)))
  (unless (= checksum 2) (error "Unexpected local-call checksum: ~S" checksum))
  (print checksum))
