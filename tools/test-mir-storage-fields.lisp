;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

;; Compare sparse traversal with the bounded field-table interpretation,
;; including unknown receivers and bits outside the local allocation graph.
(loop for size from 0 to 9 do
  (let ((fields (make-array size :initial-element nil)))
    (dotimes (id size)
      (unless (= (mod id 3) 1)
        (setf (svref fields id) (cons (ash 1 id) (ash 1 (+ id 2))))))
    (loop for mask from -16 below 1024 do
      (dolist (receivers (list mask (logior mask (ash 1 130))))
        (dolist (tail '(nil t))
          (let ((expected (logand receivers 1)))
            (dotimes (id size)
              (when (and (svref fields id) (logbitp (1+ id) receivers))
                (setf expected (logior expected
                                      (if tail (cdr (svref fields id)) (car (svref fields id)))))))
            (assert (= expected (mir-storage-field fields receivers tail)))))
        (let ((visited nil))
          (mir-do-storage-fields (id fields receivers) (push id visited))
          (assert (equal (nreverse visited)
                         (loop for id below size
                               when (and (svref fields id) (logbitp (1+ id) receivers)) collect id))))))))
(format t "Sparse storage fields preserve bounded bitmap reads and traversal order.~%")
