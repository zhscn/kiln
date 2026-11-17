;;;; Optional nested phase accounting; all state belongs to the calling dynamic scope.
(in-package #:kiln.compiler)

(defvar *compilation-metrics* nil)
(defvar *compilation-metrics-frame* nil)

(defun call-with-compilation-phase (phase function)
  (let* ((parent *compilation-metrics-frame*)
         (*compilation-metrics-frame* (vector 0 0))
         (wall (get-internal-real-time)) (cpu (get-internal-run-time)))
    (unwind-protect
         (funcall function)
      (let* ((elapsed-wall (- (get-internal-real-time) wall))
             (elapsed-cpu (- (get-internal-run-time) cpu))
             (entry (or (gethash phase *compilation-metrics*)
                        (setf (gethash phase *compilation-metrics*)
                              (vector 0 0 0 0 0 internal-time-units-per-second)))))
        (incf (svref entry 0) elapsed-wall)
        (incf (svref entry 1) elapsed-cpu)
        (incf (svref entry 2) (max 0 (- elapsed-wall (svref *compilation-metrics-frame* 0))))
        (incf (svref entry 3) (max 0 (- elapsed-cpu (svref *compilation-metrics-frame* 1))))
        (incf (svref entry 4))
        (when parent
          (incf (svref parent 0) elapsed-wall)
          (incf (svref parent 1) elapsed-cpu))))))

(defmacro with-compilation-phase ((phase) &body body)
  ;; Build the observation closure only when accounting is enabled.
  `(if *compilation-metrics*
       (call-with-compilation-phase ,phase (lambda () (locally ,@body)))
       (locally ,@body)))
