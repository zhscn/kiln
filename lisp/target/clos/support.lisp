;;;; Functions Clostrophilia expects from the implementation, in their
;;;; bootstrap versions (docs/10 §7). The switchover (M4.4) replaces the
;;;; early ones with the full protocol.

(in-package #:clostrophilia)

;;; Until the switchover, MAKE-INSTANCE fills the slots from the initargs
;;; and initforms without running INITIALIZE-INSTANCE.
(defun make-instance (class &rest initargs)
  (apply #'early-make-instance class initargs))

(defun make-method-instance (class &rest initargs)
  (apply #'make-instance class initargs))

;;; Clostrophilia's ALLOCATE-INSTANCE: instances of funcallable classes
;;; are funcallable instances.
(defun allocate-general-instance (class size)
  (%allocate class size
             (member (find-class 'funcallable-standard-object)
                     (%slot class '%precedence-list))))

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

(defun shared-initialize-aux-1 (instance class slot-names &rest initargs)
  (apply #'shared-initialize-aux instance class slot-names initargs))

(defun compile (name lambda-expression)
  (declare (ignore name))
  (error "COMPILE is not available" lambda-expression))

;;; Obsolete instances (docs/10 §7, point 8): an instance whose stamp is
;;; not the unique number of its class. The patched
;;; DEFAULT-DISCRIMINATING-FUNCTION updates them before dispatching again.
(defun obsolete-instance-p (object)
  (and (instancep object)
       (not (eql (stamp object) (%slot (class-of object) '%unique-number)))))

(defun update-obsolete-instance (instance)
  ;; Class redefinition is not supported yet, so no instance becomes
  ;; obsolete; this keeps a stale stamp from looping.
  (error "obsolete instance: class redefinition is not supported yet" instance))
