(defun raw-frame-probe ()
  (let* ((frame (find 'raw-frame-fixture (kiln.sys:frame-list) :key #'kiln.sys:frame-name))
         (names (svref (kiln.kernel::frame-debug-info frame) 4))
         (index (position 'payload names))
         (original (svref names index)))
    (unwind-protect
         (progn
           (setf (svref names index) '(:double-bits payload))
           (print (eql (cdr (assoc 'payload (kiln.sys:frame-variables frame))) 1.25d0)))
      (setf (svref names index) original))))

(defun raw-frame-fixture (payload)
  (raw-frame-probe)
  payload)

;;; This fixnum's tagged word is the binary64 encoding of 1.25. It is safe
;;; for the collector while exercising the raw debug descriptor on a live slot.
(print (= (raw-frame-fixture #x1ffa000000000000) #x1ffa000000000000))
