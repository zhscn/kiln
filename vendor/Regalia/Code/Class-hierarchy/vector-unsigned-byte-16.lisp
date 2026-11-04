(cl:in-package #:regalia)

;;; kiln: upstream defines VECTOR-UNSIGNED-BYTE-32 here a second time.
(defclass #-kiln vector-unsigned-byte-32 #+kiln vector-unsigned-byte-16
  (vector #-kiln array-unsigned-byte-32 #+kiln array-unsigned-byte-16)
  ())
