(cl:in-package #:clostrophilia)

(defun slot-boundp (object slot-name)
  (slot-boundp-using-only-class (class-of object) object slot-name))

(defun slot-value (object slot-name)
  ;; kiln: standard instances of standard classes by the slot's location
  ;; (FAST-SLOT-LOCATION, support.lisp).
  (let ((location (fast-slot-location object slot-name)))
    (if location
        (let ((value (if (consp location)
                         (car location)
                         (standard-instance-access object location))))
          (if (eq value +unbound-slot-value+)
              (values (slot-unbound (class-of object) object slot-name))
              value))
        (slot-value-using-only-class (class-of object) object slot-name))))

(defun (setf slot-value) (value object slot-name)
  (let ((location (fast-slot-location object slot-name)))
    (cond ((null location)
           (setf (slot-value-using-only-class (class-of object) object slot-name)
                 value))
          ((consp location) (setf (car location) value))
          (t (setf (standard-instance-access object location) value)))))

(defun slot-makunbound (object slot-name)
  (slot-makunbound-using-only-class (class-of object) object slot-name))
