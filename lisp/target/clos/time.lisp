;;;; Time (docs/10 §21), through the runtime's clocks (%PRIMOP :SYS). No
;;;; time zones yet, so no DECODE-UNIVERSAL-TIME.

(in-package #:kiln.kernel)

(defconstant internal-time-units-per-second 1000000)

(defun get-internal-real-time () (sys 14))

(defun get-internal-run-time () (sys 16))

(defun get-universal-time ()
  ;; Universal time of 1970-01-01T00:00:00Z.
  (+ (sys 15) 2208988800))

;;; Sleeping blocks garbage collection by other threads; there are none
;;; yet.
(defun sleep (seconds)
  (check-type seconds (real 0))
  (sys 17 (round (* seconds 1000000)))
  nil)
