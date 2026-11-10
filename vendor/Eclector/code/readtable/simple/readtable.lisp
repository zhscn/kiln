(cl:in-package #:eclector.readtable.simple)

;;; kiln: also of the built-in class CL:READTABLE (then STANDARD-OBJECT
;;; must be given).
(defclass readtable (#+kiln standard-object #+kiln cl:readtable)
  ((%syntax-types
    :initform (make-hash-table)
    :reader syntax-types)
   (%ascii-syntax-types
    :initform (make-array 128 :initial-element :constituent)
    :reader ascii-syntax-types)
   (%macro-characters
    :initform (make-hash-table)
    :reader macro-characters)
   (%dispatch-macro-characters
    :initform (make-hash-table)
    :reader dispatch-macro-characters)
   (%readtable-case :initform :upcase
                    :accessor eclector.readtable:readtable-case)))
