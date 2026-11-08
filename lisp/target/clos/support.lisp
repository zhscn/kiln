;;;; Functions Clostrophilia expects from the implementation, in their
;;;; bootstrap versions. The switchover (M4.4) replaces the
;;;; early ones with the full protocol.

(in-package #:clostrophilia)

;;; Until the switchover, MAKE-INSTANCE fills the slots from the initargs
;;; and initforms without running INITIALIZE-INSTANCE.
(defun make-instance (class &rest initargs)
  (apply (if *switched-p* #'mop-make-instance #'early-make-instance) class initargs))

(defun make-method-instance (class &rest initargs)
  (apply #'make-instance class initargs))

;;; Clostrophilia's ALLOCATE-INSTANCE: instances of funcallable classes
;;; are funcallable instances. After the switchover, whether a class is
;;; one is cached as (TYPEP instance 'FUNCALLABLE-STANDARD-OBJECT) would be
;;; (conditions.lisp).
(defvar *funcallable-standard-object* nil)

(defun allocate-general-instance (class size)
  (%allocate class size
             (if *switched-p*
                 (subclass-cached-p
                  class
                  (or *funcallable-standard-object*
                      (setf *funcallable-standard-object*
                            (find-class 'funcallable-standard-object))))
                 (member (find-class 'funcallable-standard-object)
                         (%slot class '%precedence-list)))))

;;; Method combination templates, by name.

(defun ensure-method-combination-template
    (name variant-signature-determiner effective-method-form-function
     &key documentation)
  (setf (get name '%method-combination-template)
        (make-instance 'method-combination-template
                       :name name
                       :variant-signature-determiner variant-signature-determiner
                       :effective-method-form-function effective-method-form-function
                       :documentation documentation))
  name)

(defun find-method-combination-template (client name)
  (declare (ignore client))
  (get name '%method-combination-template))

;;; Only used with classes.
(defun subtypep-1 (class-1 class-2)
  (if (member class-2 (%slot class-1 '%precedence-list)) t nil))

;;; SHARED-INITIALIZE of an instance of a class whose metaclass is
;;; STANDARD-CLASS: from a plan of the class's slots, made
;;; once, instead of calling SLOT-DEFINITION-INITARGS and
;;; (SETF SLOT-VALUE-USING-CLASS), generic functions, for each slot. A
;;; portable program may not define methods on them that apply to
;;; STANDARD-CLASS (AMOP's restrictions), as for accessor methods.
;;; The plan is made again when the class's slots change.

;;; A direct-mapped cache of (SLOTS PLAN) pairs, as *SLOT-LOCATION-CACHE*
;;; (early.lisp): a class's slot list is replaced, not changed, when the
;;; class changes. (Hash tables do not exist yet at the switchover.)
(defvar *initialization-plans* (kiln.kernel::make-simple-vector (* 2 1024) nil))
(defvar *standard-class* nil)

(defun initialization-plan (class)
  "A simple vector with, for each slot of CLASS, its initargs, location,
name and initfunction; and the slots."
  (let* ((slots (class-slots class))
         (cache *initialization-plans*)
         (index (* 2 (kiln.sys:%primop :fixnum-logand
                                       (kiln.sys:%primop :identity-hash slots)
                                       1023))))
    (if (eq (svref cache index) slots)
        (values (svref cache (+ index 1)) slots)
        (let ((plan (kiln.kernel::make-simple-vector (* 4 (length slots)) nil)))
          (loop for slot in slots
                for i from 0 by 4
                do (setf (svref plan i) (slot-definition-initargs slot)
                         (svref plan (+ i 1)) (slot-definition-location slot)
                         (svref plan (+ i 2)) (slot-definition-name slot)
                         (svref plan (+ i 3)) (slot-definition-initfunction slot)))
          (setf (svref cache index) slots
                (svref cache (+ index 1)) plan)
          (values plan slots)))))

(defun planned-shared-initialize (instance class slot-names initargs)
  (multiple-value-bind (plan slots) (initialization-plan class)
    (loop for i from 0 below (length plan) by 4
          do (let ((location (svref plan (+ i 1)))
                   (value nil)
                   (foundp nil))
               (when initargs
                 (loop with slot-initargs = (svref plan i)
                       for (key v) on initargs by #'cddr
                       when (member key slot-initargs)
                         do (setf value v foundp t)
                            (loop-finish)))
               (flet ((store (value)
                        (if (consp location)
                            (setf (car location) value)
                            (setf (standard-instance-access instance location) value))))
                 (cond (foundp (store value))
                       ((and (or (eq slot-names t)
                                 (and slot-names (member (svref plan (+ i 2)) slot-names)))
                             (svref plan (+ i 3))
                             (eq (if (consp location)
                                     (car location)
                                     (standard-instance-access instance location))
                                 +unbound-slot-value+))
                        (store (funcall (svref plan (+ i 3)))))))))
    (setf (slot-value-using-location+1 instance -1) slots))
  instance)

;;; SLOT-VALUE and (SETF SLOT-VALUE) of an instance of a class whose
;;; metaclass is STANDARD-CLASS: the slot's location from
;;; the cache of %SLOT-LOCATION, without finding the slot definition by
;;; name (FIND with SLOT-DEFINITION-NAME, a generic function, as the key)
;;; and calling SLOT-VALUE-USING-CLASS, as for accessor methods.
(defun fast-slot-location (object name)
  "The location of the slot NAME of OBJECT if OBJECT is a standard
instance of a class whose metaclass is STANDARD-CLASS and has the slot,
else NIL."
  (and *standard-class*
       (kiln.sys:%primop :standard-instance-p object)
       (eq (class-of (class-of object)) *standard-class*)
       (%find-slot-location object name)))

;;; SLOT-VALUE and (SETF SLOT-VALUE) at a call site with a constant slot
;;; name (lower.lisp): each call site has a cache, a cons of static data,
;;; whose car is the stamp of the object's class and whose cdr is the
;;; slot's location there. The stamp is the check-style guard: a class has
;;; one layout for one stamp, so the location cannot change under it. An
;;; obsolete instance keeps the stamp and the rack of the layout its class
;;; had when it was made, and reads the slot it was made with, as
;;; SLOT-VALUE does. A class-allocated slot (a location that is a cons) and
;;; an object that is not a standard instance of a standard-class go
;;; SLOT-VALUE's own way.
(defun kiln.kernel::%slot-value-cached (object slot-name cache)
  (let ((stamp (stamp object)))
    (if (eql (car cache) stamp)
        (let ((value (standard-instance-access object (cdr cache))))
          (if (eq value +unbound-slot-value+)
              (slot-unbound (class-of object) object slot-name)
              value))
        (let ((location (fast-slot-location object slot-name)))
          (if (and location (not (consp location)))
              (progn
                ;; The location first, then the stamp: no reader sees the
                ;; new stamp with the old location.
                (setf (cdr cache) location)
                (setf (car cache) stamp)
                (let ((value (standard-instance-access object location)))
                  (if (eq value +unbound-slot-value+)
                      (slot-unbound (class-of object) object slot-name)
                      value)))
              (slot-value object slot-name))))))

(defun kiln.kernel::%set-slot-value-cached (value object slot-name cache)
  (let ((stamp (stamp object)))
    (if (eql (car cache) stamp)
        (setf (standard-instance-access object (cdr cache)) value)
        (let ((location (fast-slot-location object slot-name)))
          (if (and location (not (consp location)))
              (progn
                (setf (cdr cache) location)
                (setf (car cache) stamp)
                (setf (standard-instance-access object location) value))
              (setf (slot-value object slot-name) value))))))

(defun shared-initialize-aux-1 (instance class slot-names &rest initargs)
  (when (and *switched-p* (null *standard-class*))
    (setf *standard-class* (find-class 'standard-class)))
  (if (and *standard-class* (eq (class-of class) *standard-class*))
      (planned-shared-initialize instance class slot-names initargs)
      (apply #'shared-initialize-aux instance class slot-names initargs)))

(defun compile (name lambda-expression)
  (declare (ignore name))
  (error "COMPILE is not available" lambda-expression))

;;; Obsolete instances: an instance whose stamp is
;;; not the unique number of its class. The patched
;;; DEFAULT-DISCRIMINATING-FUNCTION updates them before dispatching again.
(defun obsolete-instance-p (object)
  (and (instancep object)
       (not (kiln.sys:%primop :structure-instance-p object))
       (not (eql (stamp object) (%slot (class-of object) '%unique-number)))))

;;; UPDATE-OBSOLETE-INSTANCE: redefinition.lisp.
