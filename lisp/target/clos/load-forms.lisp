;;;; Forms for reconstructing objects and restoring their selected slots.

(in-package #:clostrophilia)

(defgeneric make-load-form (object &optional environment))

(defmethod make-load-form ((object standard-object) &optional environment)
  (declare (ignore environment))
  (error "No MAKE-LOAD-FORM method was supplied for ~S." object))

(defmethod make-load-form ((object structure-object) &optional environment)
  (declare (ignore environment))
  (error "No MAKE-LOAD-FORM method was supplied for ~S." object))

(defmethod make-load-form ((object condition) &optional environment)
  (declare (ignore environment))
  (error "No MAKE-LOAD-FORM method was supplied for ~S." object))

(defmethod make-load-form ((class class) &optional environment)
  (declare (ignore environment))
  (let ((name (class-name class)))
    (unless (and name (eq (find-class name nil) class))
      (error "Cannot reconstruct an unnamed or unregistered class ~S." class))
    `(find-class ',name)))

(defun make-load-form-saving-slots (object &key (slot-names nil slot-names-p) environment)
  (declare (ignore environment))
  (unless (typep object 'standard-object)
    (error 'type-error :datum object :expected-type 'standard-object))
  (let ((class (physical-class-of object)) (initializers nil))
    (dolist (slot (class-slots class))
      (let ((name (slot-definition-name slot)))
        (when (if slot-names-p
                  (member name slot-names)
                  (eq (slot-definition-allocation slot) :instance))
          (push (if (slot-boundp object name)
                    `(setf (slot-value ',object ',name) ',(slot-value object name))
                    `(slot-makunbound ',object ',name))
                initializers))))
    (values `(allocate-instance (find-class ',(class-name class)))
            `(progn ,@(nreverse initializers)))))
