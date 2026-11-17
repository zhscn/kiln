;;;; Kiln publishes normalized platform features before user code runs.
(in-package #:cl-user)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (dolist (feature '(:64-bit :x86-64 :little-endian :linux :unix))
    (unless (member feature *features*)
      (error "Kiln platform feature ~S is missing." feature))))
