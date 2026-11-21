(in-package #:cl-user)

(defparameter kiln.sys::*array-element-type-upgrades*
  '(nil bit (unsigned-byte 2) (unsigned-byte 4) (unsigned-byte 7)
    (signed-byte 8) (unsigned-byte 8) (unsigned-byte 15)
    (signed-byte 16) (unsigned-byte 16) (unsigned-byte 31)
    (signed-byte 32) (unsigned-byte 32) (unsigned-byte 62)
    fixnum (unsigned-byte 63) (signed-byte 64) (unsigned-byte 64)
    base-char character single-float double-float
    (complex single-float) (complex double-float) t))
