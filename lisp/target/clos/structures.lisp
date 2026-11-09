;;;; Native DEFSTRUCT instances carry an immutable layout and their slots.

(in-package #:clostrophilia)

(defclass structure-class (standard-class)
  ((%structure-layout :initform nil)))

(defclass structure-object (standard-object)
  ()
  (:metaclass structure-class))

;;; Layout vector: class, stamp, effective slots, depth, ancestors, size.
;;; The first three entries also serve the CLOS metadata locations -3..-1.
(defun ensure-structure-layout (class)
  (or (%slot class '%structure-layout)
      (progn
        (unless (class-finalized-p class) (finalize-inheritance class))
        (let* ((parent (car (class-direct-superclasses class)))
               (parent-layout (and (not (eq class (find-class 'structure-object)))
                                   (ensure-structure-layout parent)))
               (depth (if parent-layout (+ 1 (svref parent-layout 3)) 0))
               (ancestors (kiln.kernel::make-simple-vector (+ depth 1) nil))
               (layout (vector class (%slot class '%unique-number)
                               (class-slots class) depth ancestors
                               (length (class-slots class)))))
          (when parent-layout
            (dotimes (i depth)
              (setf (svref ancestors i) (svref (svref parent-layout 4) i))))
          (setf (svref ancestors depth) layout
                (%slot class '%structure-layout) layout)
          layout))))

(defun kiln.sys::%ensure-structure-layout (class)
  (ensure-structure-layout class))

(declaim (inline structure-layout-typep))
(defun structure-layout-typep (object layout)
  (and (kiln.sys:%primop :structure-instance-p object)
       (let ((actual (kiln.sys:%primop :structure-layout object)))
         (or (eq actual layout)
             (let ((depth (kiln.sys:%primop :svref-unchecked layout 3)))
               (and (kiln.sys:%primop :fixnum-le
                                      depth (kiln.sys:%primop :svref-unchecked actual 3))
                    (eq (kiln.sys:%primop :svref-unchecked
                                          (kiln.sys:%primop :svref-unchecked actual 4)
                                          depth)
                        layout)))))))

(defun copy-structure (structure)
  (unless (kiln.sys:%primop :structure-instance-p structure)
    (error 'type-error :datum structure :expected-type 'structure-object))
  (let* ((layout (kiln.sys:%primop :structure-layout structure))
         (size (kiln.sys:%primop :svref-unchecked layout 5))
         (copy (kiln.sys:%primop :allocate-structure layout size)))
    (dotimes (location size copy)
      (kiln.sys:%primop :set-structure-slot copy location
                       (kiln.sys:%primop :structure-slot structure location)))))

(defmethod allocate-instance ((class structure-class) &rest initargs)
  (declare (ignore initargs))
  (let* ((layout (ensure-structure-layout class))
         (size (kiln.sys:%primop :svref-unchecked layout 5))
         (instance (kiln.sys:%primop :allocate-structure layout size)))
    (dotimes (i size instance)
      (kiln.sys:%primop :set-structure-slot instance i +unbound-slot-value+))))

(declaim (inline kiln.sys::%structure-typep
                 kiln.sys::%structure-ref kiln.sys::%structure-set))
(defun kiln.sys::%structure-typep (object layout)
  (structure-layout-typep object layout))

(defun kiln.sys::%structure-ref (object layout name location)
  (if (structure-layout-typep object layout)
      (kiln.sys:%primop :structure-slot object location)
      (structure-access-error object name)))

(defun kiln.sys::%structure-set (value object layout name location)
  (if (structure-layout-typep object layout)
      (kiln.sys:%primop :set-structure-slot object location value)
      (structure-access-error object name)))

(defun structure-access-error (object name)
  (error 'type-error :datum object :expected-type name))
