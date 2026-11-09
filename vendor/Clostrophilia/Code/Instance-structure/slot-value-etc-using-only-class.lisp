(cl:in-package #:clostrophilia)

(defun slot-boundp-using-only-class (class object slot-name)
  (multiple-value-bind (slot present) (find-slot class object slot-name 'slot-boundp)
    (if present (values (slot-boundp-using-class class object slot)) (not (null slot)))))

(defun slot-value-using-only-class (class object slot-name)
  (multiple-value-bind (slot present) (find-slot class object slot-name 'slot-value)
    (if present (values (slot-value-using-class class object slot)) slot)))

(defun (setf slot-value-using-only-class) (new-value class object slot-name)
  (multiple-value-bind (slot present) (find-slot class object slot-name 'setf new-value)
    (when present (setf (slot-value-using-class class object slot) new-value))
    new-value))

(defun slot-makunbound-using-only-class (class object slot-name)
  (multiple-value-bind (slot present) (find-slot class object slot-name 'slot-makunbound)
    (when present (slot-makunbound-using-class class object slot))
    object))
