(cl:in-package #:regalia)

(defclass bit-vector (vector array-bit #+kiln cl:bit-vector)
  ())
