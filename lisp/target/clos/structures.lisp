;;;; Structures: DEFSTRUCT is expanded in the host by
;;;; Anatomicl (lisp/structures.lisp) into a DEFCLASS of the metaclass
;;;; STRUCTURE-CLASS, constructors, a predicate and a copier.

(in-package #:clostrophilia)

(defclass structure-class (standard-class)
  ())

(defclass structure-object (standard-object)
  ()
  (:metaclass structure-class))

;;; A structure's slots are at the locations 0 to N-1, in the order of its
;;; layout (lisp/structures.lisp): the copy takes the words as they are,
;;; unbound markers included.
(defun copy-structure (structure)
  (let* ((class (class-of structure))
         (copy (allocate-instance class)))
    (dotimes (location (length (class-slots class)) copy)
      (setf (standard-instance-access copy location)
            (standard-instance-access structure location)))))

;;; Anatomicl's constructors call ALLOCATE-INSTANCE directly, which does
;;; not finalize the class as MAKE-INSTANCE does.
(defmethod allocate-instance :before ((class structure-class) &rest initargs)
  (declare (ignore initargs))
  (unless (class-finalized-p class)
    (finalize-inheritance class)))

;;; The accessors that DEFSTRUCT defines (lisp/structures.lisp): CLASS
;;; is the structure's, LOCATION the slot's.
(declaim (inline kiln.sys::%structure-ref kiln.sys::%structure-set))
(defun kiln.sys::%structure-ref (object class name location)
  (if (and (instancep object) (eq (kiln.sys:%primop :instance-class object) class))
      (kiln.sys:%primop :standard-instance-access object location)
      (structure-ref-slow object name location)))

(defun kiln.sys::%structure-set (value object class name location)
  (if (and (instancep object) (eq (kiln.sys:%primop :instance-class object) class))
      (kiln.sys:%primop :set-standard-instance-access object location value)
      (structure-set-slow value object name location)))

(defun check-structure (object name)
  (unless (typep object name)
    (error 'type-error :datum object :expected-type name)))

(defun structure-ref-slow (object name location)
  (check-structure object name)
  (standard-instance-access object location))

(defun structure-set-slow (value object name location)
  (check-structure object name)
  (setf (standard-instance-access object location) value))
