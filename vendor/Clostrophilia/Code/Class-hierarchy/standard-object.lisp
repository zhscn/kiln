(cl:in-package #:clostrophilia)

(defclass slot-object (t) ())

(defclass standard-object (slot-object)
  ()
  (:documentation
   "This class is the root class for all standard objects."))
