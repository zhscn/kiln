;;;; Class redefinition (CLHS 4.3.6, 4.3.6.1): DEFCLASS of an existing
;;;; class reinitializes it, then finalizes it and its subclasses again.
;;;; A finalization gives a class a new unique number, so the instances
;;;; made before keep a stamp that is no longer their class's: they are
;;;; obsolete. The discriminating function's miss path (patched
;;;; DEFAULT-DISCRIMINATING-FUNCTION) updates an obsolete instance before
;;;; dispatching: its rack still holds the slot list it was made with, so
;;;; its slots can be read by their old locations. Also FIND-METHOD,
;;;; MAKE-INSTANCES-OBSOLETE and SLOT-EXISTS-P.

(in-package #:clostrophilia)

(defun slot-exists-p (object slot-name)
  (let ((class (class-of object)))
    (unless (class-finalized-p class) (finalize-inheritance class))
    (if (find slot-name (class-slots class) :key #'slot-definition-name) t nil)))

(defgeneric find-method (generic-function qualifiers specializers &optional errorp))

(defmethod find-method ((generic-function generic-function) qualifiers specializers
                        &optional (errorp t))
  (let ((specializers (mapcar #'specializer-from-designator specializers)))
    (or (find-if (lambda (method)
                   (and (equal (method-qualifiers method) qualifiers)
                        (= (length (method-specializers method)) (length specializers))
                        (every #'eq (method-specializers method) specializers)))
                 (generic-function-methods generic-function))
        (and errorp
             (error "~S has no method with qualifiers ~S and specializers ~S."
                    generic-function qualifiers specializers)))))

(defgeneric make-instances-obsolete (class))

(defmethod make-instances-obsolete ((class symbol))
  (make-instances-obsolete (find-class class))
  class)

(defmethod make-instances-obsolete ((class class))
  (when (class-finalized-p class)
    (let ((classes (refinalize class)))
      (forget-call-caches classes)))
  class)

(defgeneric update-instance-for-redefined-class
    (instance added-slots discarded-slots property-list &rest initargs
     &key &allow-other-keys))

(defmethod update-instance-for-redefined-class
    ((instance standard-object) added-slots discarded-slots property-list &rest initargs)
  (declare (ignore discarded-slots property-list))
  (apply #'shared-initialize instance added-slots initargs))

;;; Called by MOP-ENSURE-CLASS for an existing class that is not a forward
;;; reference.
(defun redefine-class (class metaclass initargs)
  (unless (eq (class-of class) metaclass)
    (error "Cannot redefine ~S with the metaclass ~S." class (class-name metaclass)))
  (remove-accessor-methods class)
  ;; The options DEFCLASS leaves out take their defaults again.
  (apply #'reinitialize-instance class
         (append initargs
                 (list :direct-default-initargs '() :documentation nil
                       :direct-slots '())))
  (forget-call-caches (refinalize class))
  class)

(defun remove-accessor-methods (class)
  "Removes the reader and writer methods of CLASS's direct slots."
  (flet ((remove-from (name specializers)
           (when (fboundp name)
             (let ((gf (fdefinition name)))
               (when (generic-function-p gf)
                 (let ((method (find-method gf '() specializers nil)))
                   (when method (remove-method gf method))))))))
    (dolist (slot (class-direct-slots class))
      (dolist (reader (slot-definition-readers slot))
        (remove-from reader (list class)))
      (dolist (writer (slot-definition-writers slot))
        (remove-from writer (list (find-class t) class))))))

(defun refinalize (class)
  "Finalizes CLASS again if it was finalized, then its subclasses; returns
CLASS and its subclasses."
  (let ((classes '()))
    (labels ((walk (class)
               (unless (member class classes)
                 (push class classes)
                 (when (class-finalized-p class)
                   (finalize-inheritance class))
                 (mapc #'walk (class-direct-subclasses class)))))
      (walk class))
    ;; The class precedence lists changed; TYPEP and SUBTYPEP answers
    ;; cached for the classes' stamps (also the old ones, still the stamps
    ;; of obsolete instances) no longer hold.
    (kiln.kernel::invalidate-type-caches)
    classes))

(defun forget-call-caches (classes)
  "Removes the call caches that mention one of CLASSES from every generic
function's call history: their applicable methods may have changed, and
the automaton built from them matches the old stamps."
  (dolist (gf *early-generic-functions*)
    (let ((history (call-history gf)))
      (when (loop for cache in history
                  thereis (loop for class in (class-cache cache)
                                thereis (member class classes)))
        (setf (call-history gf)
              (loop for cache in history
                    unless (loop for class in (class-cache cache)
                                 thereis (member class classes))
                      collect cache))
        (invalidate-discriminating-function gf)))))

(defun update-obsolete-instance (instance)
  "Brings INSTANCE, whose class was redefined after it was made, up to
date (CLHS 4.3.6.1)."
  (let* ((class (class-of instance))
         (old-slots (standard-instance-access instance -1))
         (new (progn (unless (class-finalized-p class) (finalize-inheritance class))
                     (allocate-instance class)))
         (new-slots (class-slots class))
         (added '()) (discarded '()) (property-list '()))
    (flet ((local-p (slot) (integerp (slot-definition-location slot))))
      (dolist (slot old-slots)
        (when (local-p slot)
          (let* ((name (slot-definition-name slot))
                 (value (standard-instance-access instance (slot-definition-location slot)))
                 (boundp (not (eq value +unbound-slot-value+)))
                 (new-slot (find name new-slots :key #'slot-definition-name)))
            (cond ((and new-slot (local-p new-slot))
                   (when boundp
                     (setf (standard-instance-access new (slot-definition-location new-slot))
                           value)))
                  (t
                   (push name discarded)
                   (when boundp
                     (setf property-list (list* name value property-list))))))))
      (dolist (slot new-slots)
        (when (and (local-p slot)
                   (not (find-if (lambda (old) (and (local-p old)
                                                    (eq (slot-definition-name old)
                                                        (slot-definition-name slot))))
                                 old-slots)))
          (push (slot-definition-name slot) added))))
    (kiln.sys:%primop :set-instance-rack instance (kiln.sys:%primop :instance-rack new))
    (update-instance-for-redefined-class instance (nreverse added) (nreverse discarded)
                                         property-list)
    instance))
