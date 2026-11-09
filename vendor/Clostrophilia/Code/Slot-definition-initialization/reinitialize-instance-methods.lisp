(cl:in-package #:clostrophilia)

(defmethod reinitialize-instance :before
    ((slot-definition slot-definition)
     &key)
  (error 'slot-definition-can-not-be-reininitialized
         :slot-definition slot-definition))
