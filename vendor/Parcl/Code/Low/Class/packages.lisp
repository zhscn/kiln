(cl:in-package #:common-lisp-user)

(defpackage parcl-low-class
  (:use #:common-lisp)
  ;; kiln: the package class is CL:PACKAGE.
  #-kiln (:shadow #:package)
  (:export
     #:package
     #:client
     #:name
     #:nicknames
     #:local-nicknames
     #:use-list
     #:used-by-list
     #:external-symbols
     #:internal-symbols
     #:shadowing-symbols))
