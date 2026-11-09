(cl:in-package #:clostrophilia)

;;; For the specification of this generic function, see
;;; http://metamodular.com/CLOS-MOP/allocate-instance.html
;;;
;;; This generic function is also specified in the CLHS.
;;; http://www.lispworks.com/documentation/HyperSpec/Body/f_alloca.htm#allocate-instance
(defgeneric allocate-instance (class &rest initargs))

;;; The specification includes three methods for this generic
;;; function.  The first one is specialized to STANDARD-CLASS.  The
;;; second one is specialized to FUNCALLABLE-STANDARD-CLASS.  The
;;; third one is specialized to BUILT-IN-CLASS.  The last one signals
;;; an error.

;;; ALLOCATE-INSTANCE finalizes its class before reading the instance
;;; layout. MAKE-INSTANCE also needs finalization before computing the
;;; defaulted initargs, so ALLOCATE-INSTANCE-USING-CLASS does it earlier.

;;; This method on ALLOCATE-INSTANCE is specialized to REGULAR-CLASS.
;;; Every instance of a regular class has two initial cells (the
;;; STAMP, and the list of effective slots of the class) in the rack.
;;; These cells are not counted among the slots, because they are
;;; accessed directly, using offsets.  For that reason, we must
;;; allocate more slot storage than there are slots with :INSTANCE
;;; allocation.

(defmethod allocate-instance
    ((class regular-class)
     &rest initargs
     &key (additional-size 0)
     &allow-other-keys)
  (unless (class-finalized-p class)
    (finalize-inheritance class))
  (let* ((size (+ (instance-size class) additional-size 2))
         (stamp (unique-number class))
         (slots (class-slots class))
         (instance (allocate-general-instance class size)))
    (setf (slot-value-using-location+1 instance -2) stamp
          (slot-value-using-location+1 instance -1) slots)
    instance))
