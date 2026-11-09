;;;; CHANGE-CLASS. An instance's class, stamp and slots are
;;;; in its rack: a new instance of the new class is made, the slots with
;;;; the same names copied, and the instance takes over its rack. The
;;;; slots that are new are then initialized with the initargs.
;;;; Funcallable instances have racks too, and keep their function.

(in-package #:clostrophilia)

(defgeneric change-class (instance new-class &rest initargs &key &allow-other-keys))

(defmethod change-class ((instance standard-object) (new-class symbol) &rest initargs)
  (apply #'change-class instance (find-class new-class) initargs))

(defmethod change-class ((instance standard-object) (new-class standard-class) &rest initargs)
  (apply #'change-class-by-rack instance new-class initargs))

(defmethod change-class ((instance funcallable-standard-object) (new-class symbol)
                         &rest initargs)
  (apply #'change-class instance (find-class new-class) initargs))

(defmethod change-class ((instance funcallable-standard-object)
                         (new-class funcallable-standard-class) &rest initargs)
  (apply #'change-class-by-rack instance new-class initargs))

(defgeneric update-instance-for-different-class
    (previous current &rest initargs &key &allow-other-keys))

(defmethod update-instance-for-different-class
    ((previous standard-object) (current standard-object) &rest initargs)
  (let* ((old-names (mapcar #'slot-definition-name (class-slots (physical-class-of previous))))
         (added (loop for slot in (class-slots (physical-class-of current))
                      for name = (slot-definition-name slot)
                      when (and (eq (slot-definition-allocation slot) :instance)
                                (not (member name old-names)))
                        collect name)))
    (when (and *check-initialization-arguments* initargs)
      (let ((class (physical-class-of current)))
        (check-initarg-shape class initargs)
        (multiple-value-bind (keys allow-other-keys)
            (initialization-argument-policy
             class (list (compute-applicable-methods
                          #'update-instance-for-different-class (list previous current))
                         (compute-applicable-methods #'shared-initialize (list current added))))
          (check-initialization-keys class initargs keys allow-other-keys))))
    (apply #'shared-initialize current added initargs)))

(defun change-class-by-rack (instance new-class &rest initargs)
  (when (or (kiln.sys:%primop :structure-instance-p instance)
            (eq (physical-class-of new-class) (find-class 'structure-class)))
    (error "CHANGE-CLASS does not accept structure objects or structure classes."))
  (unless (class-finalized-p new-class)
    (finalize-inheritance new-class))
  (let* ((old-class (physical-class-of instance))
         (new (allocate-instance new-class))
         (old-names (mapcar #'slot-definition-name (class-slots old-class))))
    (dolist (slot (class-slots new-class))
      (let ((name (slot-definition-name slot)))
        (when (and (eq (slot-definition-allocation slot) :instance)
                   (member name old-names) (slot-boundp instance name))
          (setf (slot-value new name) (slot-value instance name)))))
    (let ((old-rack (kiln.sys:%primop :instance-rack instance))
          (new-rack (kiln.sys:%primop :instance-rack new)))
      (kiln.sys:%primop :set-instance-rack new old-rack)
      (kiln.sys:%primop :set-instance-rack instance new-rack))
    (apply #'update-instance-for-different-class new instance initargs)
    instance))
