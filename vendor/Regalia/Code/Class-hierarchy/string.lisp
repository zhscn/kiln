(cl:in-package #:regalia)

(defclass string (vector array-character #+kiln cl:string)
  ())
