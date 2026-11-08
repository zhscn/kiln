;;;; The switchover from the early functions to the MOP.
;;;;
;;;; While the early discriminating functions are still installed, every
;;;; generic function gets the standard method combination and is
;;;; satiated: its call history gets an entry for each combination of
;;;; classes (among the classes that exist now) that its methods apply to,
;;;; computed by Clostrophilia (COMPUTE-APPLICABLE-METHODS-USING-CLASSES,
;;;; COMPUTE-EFFECTIVE-METHOD). Then the discriminating functions computed
;;;; from those call histories are installed, all at once. Calls with new
;;;; classes go to DEFAULT-DISCRIMINATING-FUNCTION, whose own generic
;;;; function calls hit the satiated entries.
;;;;
;;;; After the switchover, DEFCLASS, DEFGENERIC, DEFMETHOD and
;;;; MAKE-INSTANCE use the full protocol (INITIALIZE-INSTANCE,
;;;; FINALIZE-INHERITANCE, ADD-METHOD, ...).

(in-package #:clostrophilia)

;;; The MOP versions of the entry points.

(defun mop-make-instance (class &rest initargs)
  (when (symbolp class)
    (setf class (find-class class)))
  ;; The common case without the generic protocol (constructors.lisp).
  (when (and (fboundp 'cached-fast-construction-p) (cached-fast-construction-p class))
    (return-from mop-make-instance (construct-instance class initargs)))
  (multiple-value-bind (instance defaulted-initargs)
      (apply #'allocate-instance-using-class class initargs)
    (apply #'initialize-instance instance defaulted-initargs)
    instance))

(defun remove-keys (plist keys)
  (loop for (key value) on plist by #'cddr
        unless (member key keys)
          append (list key value)))

;;; A superclass that is not defined yet is a forward-referenced class.
;;; When it is defined, the forward reference itself becomes the class
;;; (CHANGE-CLASS, then INITIALIZE-INSTANCE with the DEFCLASS's initargs),
;;; so that the classes that refer to it, and the methods specialized on
;;; it (its slot readers), see one object.
(defun ensure-superclass (name)
  (or (find-class name nil)
      (setf (find-class name)
            (make-instance 'forward-referenced-class :name name))))

(defun same-structure-definition-p (class direct-superclasses initargs)
  (and (equal (class-direct-superclasses class)
              (loop for super in direct-superclasses
                    collect (if (symbolp super) (find-class super nil) super)))
       (equal (mapcar #'slot-definition-name (class-direct-slots class))
              (loop for spec in (getf initargs :direct-slots)
                    collect (if (consp spec) (getf spec :name) spec)))))

(defun mop-ensure-class (name &rest initargs
                         &key (metaclass 'standard-class) direct-superclasses
                         &allow-other-keys)
  (let ((existing (find-class name nil)))
    ;; A structure defined again with the same included structure and slot
    ;; names (a file loaded again) keeps its class and layout, so that the
    ;; existing instances still satisfy the accessors. A different
    ;; definition gets a new class and layout; old instances keep the old
    ;; class.
    (when (and existing
               (eq (class-of existing) (find-class 'structure-class nil)))
      (if (same-structure-definition-p existing direct-superclasses initargs)
          (return-from mop-ensure-class existing)
          (setf existing nil)))
    ;; A class that is defined again (redefinition.lisp).
    (when (and existing (not (typep existing 'forward-referenced-class)))
      (return-from mop-ensure-class
        (redefine-class existing
                        (if (symbolp metaclass) (find-class metaclass) metaclass)
                        (list* :direct-superclasses
                               (loop for super in direct-superclasses
                                     collect (if (symbolp super) (ensure-superclass super) super))
                               (remove-keys initargs '(:name :metaclass :direct-superclasses))))))
    (let* ((metaclass (if (symbolp metaclass) (find-class metaclass) metaclass))
           (superclasses (loop for super in direct-superclasses
                               collect (if (symbolp super) (ensure-superclass super) super)))
           (initargs (list* :name name
                            :direct-superclasses superclasses
                            (remove-keys initargs
                                         '(:name :metaclass :direct-superclasses))))
           (class (if existing
                      (apply #'initialize-instance
                             ;; CHANGE-CLASS's SHARED-INITIALIZE runs the
                             ;; :AFTER method of classes.
                             (let ((*existing-superclasses* '()))
                               (change-class existing metaclass))
                             initargs)
                      (apply #'make-instance metaclass initargs))))
      (setf (find-class name) class)
      class)))

(defun mop-ensure-generic-function
    (name &key lambda-list (argument-precedence-order nil apo-p)
            (generic-function-class 'standard-generic-function)
            (method-class 'standard-method)
            (method-combination-name 'standard)
            (method-combination-arguments '())
            documentation)
  (let ((existing (and (fboundp name) (fdefinition name))))
    (cond ((generic-function-p existing) existing)
          ((and (fboundp name) (not (eq generic-function-class 'standard-generic-function)))
           (error "not a generic function" name))
          (t
           (let ((gf (apply #'make-instance generic-function-class
                            :name name
                            :lambda-list lambda-list
                            :method-class (if (symbolp method-class)
                                              (find-class method-class)
                                              method-class)
                            :method-combination (find-method-combination
                                                 nil method-combination-name
                                                 method-combination-arguments)
                            :documentation documentation
                            (if apo-p
                                (list :argument-precedence-order argument-precedence-order)
                                '()))))
             (setf (fdefinition name) gf)
             ;; All the generic functions, for class redefinition.
             (push gf *early-generic-functions*)
             gf)))))

(defun mop-ensure-method (name &key lambda-list qualifiers specializers documentation function
                                   fast-function)
  (let* ((gf (mop-ensure-generic-function
              name :lambda-list (congruent-lambda-list lambda-list)))
         (method (make-instance (generic-function-method-class gf)
                                :lambda-list lambda-list
                                :qualifiers qualifiers
                                :specializers (mapcar #'specializer-from-designator specializers)
                                :function function
                                :fast-function fast-function
                                :documentation documentation)))
    (add-method gf method)
    method))

;;; Satiation

(defvar *satiation-limit* 4000
  "Generic functions with more class combinations than this are not
satiated; their call histories fill as they are called.")

(defun all-classes ()
  (mapcar (lambda (d) (desc-class d)) *descriptions*))

(defun candidate-classes (methods position)
  (let ((result '()))
    (dolist (method methods)
      (let ((specializer (nth position (%slot method '%specializers))))
        (if (eq (class-of specializer) (find-class 'eql-specializer))
            (pushnew (class-of (%slot specializer '%object)) result)
            (dolist (class (all-classes))
              (when (member specializer (%slot class '%precedence-list))
                (pushnew class result))))))
    result))

(defun cartesian-product (sets)
  (if (null sets)
      (list '())
      (let ((rest (cartesian-product (rest sets))))
        (loop for x in (first sets)
              append (loop for tail in rest collect (cons x tail))))))

(defun satiate (gf)
  (let* ((profile (%slot gf '%specializer-profile))
         (methods (%slot gf '%methods))
         (class-t (find-class 't))
         (sets (loop for p in profile
                     for position from 0
                     collect (if p (candidate-classes methods position) (list class-t)))))
    (when (and methods
               (<= (reduce #'* (mapcar #'length sets)) *satiation-limit*))
      (dolist (classes (cartesian-product sets))
        (multiple-value-bind (applicable ok)
            (compute-applicable-methods-using-classes gf classes)
          (when (and ok
                     (some (lambda (m) (null (%slot m '%qualifiers))) applicable))
            (add-call-cache gf classes
                            (loop for class in classes
                                  for p in profile
                                  when p collect class)
                            applicable)))))))

(defun switch-to-mop ()
  (let ((standard (find-method-combination nil 'standard '()))
        (gfs (reverse *early-generic-functions*)))
    (dolist (gf gfs)
      (setf (%slot gf '%method-combination) standard
            (%slot gf '%call-history) '()))
    (dolist (gf gfs)
      (satiate gf))
    (let ((functions (mapcar #'compute-discriminating-function gfs)))
      (loop for gf in gfs
            for function in functions
            do (set-funcallable-instance-function gf function)))
    (setf *switched-p* t)))

(switch-to-mop)

;;; CL:ENSURE-GENERIC-FUNCTION (Iconoclast calls it at load time).
(defun cl:ensure-generic-function
    (name &rest initargs &key environment declare method-combination &allow-other-keys)
  (declare (ignore environment declare))
  (apply #'mop-ensure-generic-function name
         (append (and method-combination
                      (list :method-combination-name (first method-combination)
                            :method-combination-arguments (rest method-combination)))
                 (remove-keys initargs '(:environment :declare :method-combination)))))
