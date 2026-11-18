;;;; Optional nested phase accounting; all state belongs to the calling dynamic scope.
(in-package #:kiln.compiler)

(defvar *compilation-metrics* nil)
(defvar *compilation-metrics-frame* nil)
(defvar *compilation-metric-details* nil)

(defun add-compilation-metric (table key wall cpu own-wall own-cpu)
  (let ((entry (or (gethash key table)
                   (setf (gethash key table) (vector 0 0 0 0 0 internal-time-units-per-second)))))
    (incf (svref entry 0) wall)
    (incf (svref entry 1) cpu)
    (incf (svref entry 2) own-wall)
    (incf (svref entry 3) own-cpu)
    (incf (svref entry 4))))

(defun call-with-compilation-phase (phase function &optional detail)
  (let* ((parent *compilation-metrics-frame*)
         (*compilation-metrics-frame* (vector 0 0))
         (wall (get-internal-real-time)) (cpu (get-internal-run-time)))
    (unwind-protect
         (funcall function)
      (let* ((elapsed-wall (- (get-internal-real-time) wall))
             (elapsed-cpu (- (get-internal-run-time) cpu))
             (own-wall (max 0 (- elapsed-wall (svref *compilation-metrics-frame* 0))))
             (own-cpu (max 0 (- elapsed-cpu (svref *compilation-metrics-frame* 1)))))
        (add-compilation-metric *compilation-metrics* phase elapsed-wall elapsed-cpu own-wall own-cpu)
        (when detail
          (add-compilation-metric *compilation-metric-details* detail elapsed-wall elapsed-cpu own-wall own-cpu))
        (when parent
          (incf (svref parent 0) elapsed-wall)
          (incf (svref parent 1) elapsed-cpu))))))

(defmacro with-compilation-phase ((phase &optional detail) &body body)
  ;; Build the observation closure only when accounting is enabled.
  `(if *compilation-metrics*
       (call-with-compilation-phase ,phase (lambda () (locally ,@body))
                                    ,(when detail `(and *compilation-metric-details* ,detail)))
       (locally ,@body)))
