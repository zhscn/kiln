;;;; Structures (docs/10 §15): DEFSTRUCT is expanded in the host by
;;;; Anatomicl (lisp/structures.lisp) into a DEFCLASS of the metaclass
;;;; STRUCTURE-CLASS, constructors, a predicate and a copier.

(in-package #:clostrophilia)

(defclass structure-class (standard-class)
  ())

(defclass structure-object (standard-object)
  ()
  (:metaclass structure-class))

(defun copy-structure (structure)
  (let* ((class (class-of structure))
         (copy (allocate-instance class)))
    (dolist (slot (class-slots class) copy)
      (let ((name (slot-definition-name slot)))
        (when (slot-boundp structure name)
          (setf (slot-value copy name) (slot-value structure name)))))))

;;; Anatomicl's constructors call ALLOCATE-INSTANCE directly, which does
;;; not finalize the class as MAKE-INSTANCE does.
(defmethod allocate-instance :before ((class structure-class) &rest initargs)
  (declare (ignore initargs))
  (unless (class-finalized-p class)
    (finalize-inheritance class)))
