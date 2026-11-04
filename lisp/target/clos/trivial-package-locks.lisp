;;;; Trinsic's intrinsic interfaces are wrapped in this macro; kiln has no
;;;; package locks.

(in-package #:trivial-package-locks)

(defmacro with-unlocked-packages ((&rest packages) &body body)
  (declare (ignore packages))
  `(progn ,@body))
