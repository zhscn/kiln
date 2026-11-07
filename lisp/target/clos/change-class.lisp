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

(defun change-class-by-rack (instance new-class &rest initargs)
  (unless (class-finalized-p new-class)
    (finalize-inheritance new-class))
  (let* ((old-class (class-of instance))
         (new (allocate-instance new-class))
         (old-names (mapcar #'slot-definition-name (class-slots old-class)))
         (added '()))
    (dolist (slot (class-slots new-class))
      (let ((name (slot-definition-name slot)))
        (if (member name old-names)
            (when (slot-boundp instance name)
              (setf (slot-value new name) (slot-value instance name)))
            (push name added))))
    (kiln.sys:%primop :set-instance-rack instance (kiln.sys:%primop :instance-rack new))
    (apply #'shared-initialize instance (reverse added) initargs)
    instance))
