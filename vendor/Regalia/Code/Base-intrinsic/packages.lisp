(cl:in-package #:common-lisp-user)

(defpackage #:regalia
  (:use #:common-lisp)
  ;; kiln: simple vectors and strings are native objects, and the CL
  ;; array functions are kiln's (docs/10 §14); Regalia's classes and
  ;; functions have their own names.
  #+kiln
  (:shadow #:array #:vector #:string #:simple-vector #:bit-vector
           #:make-array #:aref #:row-major-aref #:array-dimensions
           #:array-dimension #:array-rank #:array-total-size #:arrayp
           #:adjustable-array-p #:array-displacement #:array-in-bounds-p
           #:array-row-major-index #:upgraded-array-element-type
           #:array-dimension-limit #:array-total-size-limit
           #:array-rank-limit)
  (:export
   #:make-array-instance
   #:t-aref
   #:signed-64-bit-aref
   #:unsigned-64-bit-aref
   #:signed-32-bit-aref
   #:unsigned-32-bit-aref
   #:signed-16-bit-aref
   #:unsigned-16-bit-aref
   #:signed-8-bit-aref
   #:unsigned-8-bit-aref
   #:single-float-aref
   #:double-float-aref
   #:complex-single-float-aref
   #:complex-double-float-aref
   #:character-aref
   #:bit-aref))
