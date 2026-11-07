;;;; The CLOS bootstrap, before Clostrophilia's code is loaded (docs/10 §7).
;;;;
;;;; - The primitives Clostrophilia expects from the implementation.
;;;; - DEFCLASS, DEFGENERIC and DEFMETHOD land in KILN.SYS:%DEFCLASS,
;;;;   %DEFGENERIC and %DEFMETHOD. Until the braid is built, %DEFCLASS only
;;;;   records the class and the other two are deferred.
;;;; - BUILD-CLASSES computes, from class DESCRIPTIONS, the class precedence
;;;;   lists and effective slots with Clostrophilia's algorithms, then makes
;;;;   the class, slot definition and accessor metaobjects with all their
;;;;   slots filled as Clostrophilia's initialization and finalization would.
;;;;   The braid is all recorded classes at once; afterwards each early
;;;;   DEFCLASS goes through it on its own.
;;;; - Early generic functions are real generic function metaobjects whose
;;;;   discriminating function is EARLY-DISCRIMINATE: applicable methods by
;;;;   class precedence lists, standard method combination, no caching.
;;;;
;;;; Metaobject slots are read here by name through the instance's slot
;;;; list (rack location -1), never through generic functions.

(in-package #:clostrophilia)

;;; Primitives

;;; Open-coded where they are called (docs/08 §8).
(declaim (inline standard-instance-access slot-value-using-location+1
                 slot-boundp-using-location+1 slot-makunbound-using-location+1
                 small-integer= small-integer< instancep class-of+1 stamp+1))

(defvar +unbound-slot-value+ (kiln.sys:%primop :unbound-slot-value))

(defun standard-instance-access (instance location)
  (kiln.sys:%primop :standard-instance-access instance location))

(defun (setf standard-instance-access) (value instance location)
  (kiln.sys:%primop :set-standard-instance-access instance location value))

(defun slot-value-using-location+1 (instance location)
  (standard-instance-access instance location))

(defun (setf slot-value-using-location+1) (value instance location)
  (setf (standard-instance-access instance location) value))

(defun slot-boundp-using-location+1 (instance location)
  (not (eq (standard-instance-access instance location) +unbound-slot-value+)))

(defun slot-makunbound-using-location+1 (instance location)
  (setf (standard-instance-access instance location) +unbound-slot-value+))

(defun small-integer= (x y) (= x y))
(defun small-integer< (x y) (< x y))

(defun instancep (object)
  (or (kiln.sys:%primop :standard-instance-p object)
      (kiln.sys:%primop :funcallable-instance-p object)))

(defun %allocate (class size funcallable-p)
  "An instance of CLASS with SIZE rack cells after the class (stamp, slot
list, slots), the slots unbound."
  (let ((instance (if funcallable-p
                      (kiln.sys:%primop :allocate-general-funcallable-instance class size)
                      (kiln.sys:%primop :allocate-general-instance class size))))
    (loop for location from 0 below (- size 2)
          do (setf (standard-instance-access instance location) +unbound-slot-value+))
    instance))

(defun set-funcallable-instance-function (funcallable-instance function)
  (kiln.sys:%primop :set-funcallable-instance-function funcallable-instance function))

(defun set-class-word (instance class)
  ;; Rack word 1 is location -3.
  (setf (standard-instance-access instance -3) class))

;;; Class names. The class of a name is on the symbol's plist.

(defun find-class (name &optional (errorp t) environment)
  (declare (ignore environment))
  (or (get name '%class)
      (when errorp (error "no class named" name))))

(defun (setf find-class) (class name &optional errorp environment)
  (declare (ignore errorp environment))
  (kiln.kernel::invalidate-type-caches)
  (setf (get name '%class) class))

(defun find-class-t () (find-class 't))

;;; Early slot access: by name, through the slot list in the rack. The
;;; effective slot definitions in that list are themselves read at fixed
;;; locations, recorded when their class is built.

(defvar *slot-name-location*)
(defvar *slot-location-location*)

;;; A direct-mapped cache of (SLOTS NAME LOCATION) triples, SLOTS being the
;;; slot list of an instance's class: CLASS-TYPEP and the method functions
;;; read slots by name at every call. A class's slot list is replaced, not
;;; changed, when the class changes.
(defvar *slot-location-cache* (kiln.kernel::make-simple-vector (* 3 256) nil))

(defun %slot-location (object name)
  (or (%find-slot-location object name)
      (error "no slot named" name object)))

(defun %find-slot-location (object name)
  "The location of the slot NAME of OBJECT, or NIL if it has none."
  (let* ((slots (standard-instance-access object -1))
         (cache *slot-location-cache*)
         (index (* 3 (kiln.sys:%primop :fixnum-logand
                                       (kiln.sys:%primop :fixnum-logxor
                                                         (kiln.sys:%primop :identity-hash slots)
                                                         (kiln.sys:%primop :identity-hash name))
                                       255))))
    (if (and (eq (svref cache index) slots) (eq (svref cache (+ index 1)) name))
        (svref cache (+ index 2))
        (let ((location
                (loop for slot in slots
                      when (eq (standard-instance-access slot *slot-name-location*) name)
                        return (standard-instance-access slot *slot-location-location*))))
          (when location
            (setf (svref cache index) slots
                  (svref cache (+ index 1)) name
                  (svref cache (+ index 2)) location))
          location))))

(defun %slot (object name)
  (let ((location (%slot-location object name)))
    (if (consp location)
        (car location)
        (standard-instance-access object location))))

(defun (setf %slot) (value object name)
  (let ((location (%slot-location object name)))
    (if (consp location)
        (setf (car location) value)
        (setf (standard-instance-access object location) value))))

(defun %slot-boundp (object name)
  (not (eq (%slot object name) +unbound-slot-value+)))

;;; CLASS-OF and STAMP. Objects other than instances belong to the built-in
;;; classes defined in built-in-classes.lisp.

(defvar *built-in-class-names*
  #(fixnum character cons null symbol simple-string simple-vector bignum ratio
    single-float double-float complex function t))

;;; The index in *BUILT-IN-CLASS-NAMES* of the class of OBJECT, which is not
;;; an instance; the most frequent kinds first.
(defun built-in-class-index (object)
  (cond ((kiln.kernel::fixnump object) 0)
        ((characterp object) 1)
        ((consp object) 2)
        ((null object) 3)
        ((symbolp object) 4)
        ((kiln.kernel::simple-string-p object) 5)
        ((simple-vector-p object) 6)
        ((kiln.kernel::bignump object) 7)
        ((kiln.kernel::ratiop object) 8)
        ((kiln.kernel::single-float-p object) 9)
        ((kiln.kernel::double-float-p object) 10)
        ((complexp object) 11)
        ((functionp object) 12)
        (t 13)))

(defun built-in-class-name-of (object)
  (svref *built-in-class-names* (built-in-class-index object)))

;;; The classes and stamps of the built-in classes, by index, cached after
;;; the switchover to the MOP (switchover.lisp): built-in classes are not
;;; redefined.
(defvar *built-in-classes* (kiln.kernel::make-simple-vector 14 nil))
(defvar *built-in-stamps* (kiln.kernel::make-simple-vector 14 nil))
(defvar *switched-p* nil)

(defun class-of (object)
  (if (instancep object)
      (kiln.sys:%primop :instance-class object)
      (let* ((index (built-in-class-index object))
             (class (svref *built-in-classes* index)))
        (or class
            (let ((class (find-class (svref *built-in-class-names* index))))
              (when *switched-p*
                (setf (svref *built-in-classes* index) class))
              class)))))

(defun stamp (object)
  (if (instancep object)
      (standard-instance-access object -2)
      (let* ((index (built-in-class-index object))
             (stamp (svref *built-in-stamps* index)))
        (or stamp
            (let ((stamp (%slot (class-of object) '%unique-number)))
              (when *switched-p*
                (setf (svref *built-in-stamps* index) stamp))
              stamp)))))

(defun class-of+1 (object) (class-of object))
(defun stamp+1 (object) (stamp object))

(defvar *class-unique-number* 0)

(defun new-unique-number ()
  (prog1 *class-unique-number* (incf *class-unique-number*)))

;;; Class descriptions. A description is a simple vector; it outlives the
;;; bootstrap only until the switchover to the MOP (M4.4).

(defmacro define-description-accessors (&rest names)
  `(progn
     ,@(let ((i -1))
         (mapcar (lambda (name)
                   (setq i (+ i 1))
                   `(progn (defun ,name (d) (svref d ,i))
                           (defun (setf ,name) (value d) (setf (svref d ,i) value))))
                 names))))

(define-description-accessors
  desc-name desc-supers desc-direct-slots desc-direct-default-initargs
  desc-metaclass desc-documentation
  desc-cpl                              ; descriptions, most specific first
  desc-eslots                           ; effective slot specifications
  desc-instance-size desc-class desc-unique-number
  desc-dslot-objects desc-eslot-objects desc-default-initargs
  desc-funcallable-p)

(defun make-description (name initargs)
  (let ((d (make-array 15 :initial-element nil)))
    (setf (desc-name d) name
          (desc-supers d) (getf initargs :direct-superclasses)
          (desc-direct-slots d) (getf initargs :direct-slots)
          (desc-direct-default-initargs d) (getf initargs :direct-default-initargs)
          (desc-metaclass d) (getf initargs :metaclass 'standard-class)
          (desc-documentation d) (getf initargs :documentation))
    (when (null (desc-supers d))
      (setf (desc-supers d)
            (case (desc-metaclass d)
              (standard-class (list 'standard-object))
              (funcallable-standard-class (list 'funcallable-standard-object))
              (t '()))))
    d))

(defun description (name)
  (or (get name '%description)
      (error "no class description for" name)))

(defun built-in-description-p (d)
  (eq (desc-metaclass d) 'built-in-class))

;;; Class precedence list: Clostrophilia's
;;; COMPUTE-CLASS-PRECEDENCE-LIST-ASSUMING-SUPERCLASSES-FINALIZED, on
;;; descriptions. The order of operations is kept so that the result is
;;; the same as when Clostrophilia computes it.

(defun description-supers (d)
  (mapcar #'description (desc-supers d)))

(defun compute-description-cpl (class)
  (flet ((compute-relation (class)
           (loop for prev = class then super
                 for super in (description-supers class)
                 collect (cons prev super))))
    (let* ((all-supers (cons class
                             (remove-duplicates
                              (reduce #'append
                                      (mapcar (lambda (d) (desc-cpl d))
                                              (description-supers class))))))
           (relation (loop for class in all-supers
                           append (compute-relation class)))
           (reverse-result '()))
      (flet ((find-candidate ()
               (let ((candidates
                       (loop for super in all-supers
                             unless (find super relation :key #'cdr)
                               collect super)))
                 (when (null candidates)
                   (error "unable to compute the class precedence list of"
                          (desc-name class)))
                 (if (null (cdr candidates))
                     (car candidates)
                     (loop for element in reverse-result
                           do (loop for candidate in candidates
                                    do (when (member candidate (description-supers element))
                                         (return-from find-candidate candidate))))))))
        (loop until (null all-supers)
              do (let ((candidate (find-candidate)))
                   (push candidate reverse-result)
                   (setf all-supers (remove candidate all-supers))
                   (setf relation (remove candidate relation :key #'car)))))
      (reverse reverse-result))))

;;; Effective slots: Clostrophilia's COMPUTE-SLOTS and
;;; COMPUTE-EFFECTIVE-SLOT-DEFINITION for REAL-CLASS, on the canonicalized
;;; direct slot specifications. An effective slot specification is a
;;; property list with :NAME, :ALLOCATION, :INITARGS, :TYPE, :LOCATION
;;; (:CLASS for a shared slot, resolved when the metaobjects exist),
;;; :DIRECT (the first direct slot specification) and, when there is an
;;; initform, :INITFORM and :INITFUNCTION.

(defun dslot-allocation (spec) (getf spec :allocation :instance))
(defun dslot-type (spec) (getf spec :type t))

(defun compute-description-eslots (class)
  (let* ((superclasses (desc-cpl class))
         (direct-slots (mapcar (lambda (d) (desc-direct-slots d)) superclasses))
         (concatenated (reduce #'append direct-slots))
         (reverse-slots (reverse direct-slots))
         (reverse-concatenated (reduce #'append reverse-slots))
         (names (mapcar (lambda (s) (getf s :name)) reverse-concatenated))
         (unique (remove-duplicates names :from-end t))
         (next-location 0))
    (loop for name in unique
          collect
          (let* ((direct (remove name concatenated
                                 :key (lambda (s) (getf s :name)) :test-not #'eq))
                 (allocation (dslot-allocation (first direct)))
                 (initargs (reduce #'union
                                   (mapcar (lambda (s) (getf s :initargs)) direct)))
                 (first-init (find-if-not #'null direct
                                          :key (lambda (s) (getf s :initfunction))))
                 (type `(and ,@(mapcar #'dslot-type direct)))
                 (location (if (eq allocation :class)
                               :class
                               (prog1 next-location (incf next-location)))))
            (append (list :name name :allocation allocation :initargs initargs
                          :type type :location location :direct (first direct))
                    (if (null first-init)
                        '()
                        (list :initform (getf first-init :initform)
                              :initfunction (getf first-init :initfunction))))))))

(defun compute-description-default-initargs (class)
  (remove-duplicates
   (reduce #'append (mapcar (lambda (d) (desc-direct-default-initargs d))
                            (desc-cpl class)))
   :test #'eq :key #'car :from-end t))

;;; Making instances from descriptions. The slot values come from
;;; OVERRIDES (an alist from slot name to value), then INITARGS, then the
;;; initfunction; otherwise the slot is unbound.

(defun fill-slots (instance class initargs overrides)
  (loop for eslot in (desc-eslots class)
        for name = (getf eslot :name)
        for location = (getf eslot :location)
        unless (eq location :class)
          do (let ((override (assoc name overrides))
                   (value +unbound-slot-value+))
               (if override
                   (setf value (cdr override))
                   (multiple-value-bind (key initarg-value foundp)
                       (get-properties initargs (getf eslot :initargs))
                     (declare (ignore key))
                     (cond (foundp (setf value initarg-value))
                           ((getf eslot :initfunction)
                            (setf value (funcall (getf eslot :initfunction)))))))
               (setf (standard-instance-access instance location) value)))
  instance)

(defun default-initargs (class initargs)
  (let ((result initargs))
    (loop with default = (list nil)
          for (name form thunk) in (desc-default-initargs class)
          do (when (eq (getf initargs name default) default)
               (setf result (append result (list name (funcall thunk))))))
    result))

(defun set-instance-header (instance class)
  (setf (standard-instance-access instance -2) (desc-unique-number class)
        (standard-instance-access instance -1) (desc-eslot-objects class)))

(defun make-from-description (class initargs &optional overrides)
  (let ((instance (%allocate (desc-class class) (+ (desc-instance-size class) 2)
                             (desc-funcallable-p class))))
    (set-instance-header instance class)
    (fill-slots instance class (default-initargs class initargs) overrides)))

(defun early-make-instance (class &rest initargs)
  (make-from-description (description (if (symbolp class) class (%slot class '%name)))
                         initargs))

;;; Building classes

(defvar *braid-built-p* nil)
(defvar *early-generic-functions* '()
  "The generic functions made before the switchover, most recent first;
after it, ENSURE-GENERIC-FUNCTION adds the new ones (redefinition.lisp
goes through them).")
(defvar *switched-p* nil
  "True after the switchover to the MOP (switchover.lisp).")
(defvar *class-records* '()
  "(NAME . INITARGS) of each DEFCLASS before the braid, most recent first.")
(defvar *deferred-definitions* '()
  "Thunks for the DEFGENERIC and DEFMETHOD forms evaluated before the
braid, most recent first.")

(defun description-funcallable-p (d)
  (member (description 'funcallable-standard-object) (desc-cpl d)))

(defun build-classes (descriptions)
  "Makes the class metaobjects of DESCRIPTIONS, which are in an order where
superclasses and metaclasses come first or are built already."
  (dolist (d descriptions)
    (setf (get (desc-name d) '%description) d))
  ;; Pure computations.
  (dolist (d descriptions)
    (setf (desc-cpl d) (compute-description-cpl d))
    (setf (desc-eslots d) (compute-description-eslots d))
    (setf (desc-instance-size d)
          (count :instance (desc-eslots d) :key #'dslot-allocation))
    (setf (desc-default-initargs d) (compute-description-default-initargs d))
    (setf (desc-unique-number d) (new-unique-number)))
  (dolist (d descriptions)
    (setf (desc-funcallable-p d) (description-funcallable-p d)))
  ;; The class metaobjects, allocated first so that they can refer to each
  ;; other; the slots are filled once the slot definitions exist.
  (dolist (d descriptions)
    (let* ((metaclass (description (desc-metaclass d)))
           (class (%allocate nil (+ (desc-instance-size metaclass) 2) nil)))
      (setf (desc-class d) class)
      (setf (find-class (desc-name d)) class)))
  (dolist (d descriptions)
    (set-class-word (desc-class d) (desc-class (description (desc-metaclass d)))))
  (let ((dsd (description 'standard-direct-slot-definition))
        (esd (description 'standard-effective-slot-definition))
        (new '()))
    (flet ((make (class initargs)
             ;; Headers are set at the end, when every class has its
             ;; effective slot definitions.
             (let ((instance (%allocate (desc-class class) (+ (desc-instance-size class) 2)
                                        (desc-funcallable-p class))))
               (push (cons instance class) new)
               (fill-slots instance class (default-initargs class initargs) '()))))
      (dolist (d descriptions)
        (setf (desc-dslot-objects d)
              (mapcar (lambda (spec) (make dsd spec)) (desc-direct-slots d))))
      (dolist (d descriptions)
        (setf (desc-eslot-objects d)
              (loop for eslot in (desc-eslots d)
                    collect
                    (let ((location (getf eslot :location)))
                      (when (eq location :class)
                        (setf location (direct-slot-storage eslot)))
                      (make esd (append (list :name (getf eslot :name)
                                              :allocation (getf eslot :allocation)
                                              :location location
                                              :initargs (getf eslot :initargs)
                                              :type (getf eslot :type))
                                        (if (getf eslot :initfunction)
                                            (list :initform (getf eslot :initform)
                                                  :initfunction (getf eslot :initfunction))
                                            '())))))))
      (dolist (instance-and-class new)
        (set-instance-header (car instance-and-class) (cdr instance-and-class))))
    (let ((name-eslot (find '%name (desc-eslots esd) :key (lambda (s) (getf s :name))))
          (location-eslot (find '%location (desc-eslots esd) :key (lambda (s) (getf s :name)))))
      (setf *slot-name-location* (getf name-eslot :location)
            *slot-location-location* (getf location-eslot :location))))
  (dolist (d descriptions)
    (fill-class-slots d))
  (dolist (d descriptions)
    (unless (built-in-description-p d)
      (loop for dslot in (desc-dslot-objects d)
            do (add-accessor-methods (desc-class d) dslot))))
  (mapcar (lambda (d) (desc-class d)) descriptions))

(defun direct-slot-storage (eslot)
  ;; The location of a shared slot is the storage cons of the direct slot
  ;; definition that gave the slot its allocation.
  (let ((direct (getf eslot :direct)))
    (dolist (d (list-all-descriptions))
      (loop for spec in (desc-direct-slots d)
            for object in (desc-dslot-objects d)
            do (when (eq spec direct)
                 ;; The headers are not set yet: read the slot at its
                 ;; location in the description.
                 (return-from direct-slot-storage
                   (standard-instance-access
                    object (description-slot-location
                            (description 'standard-direct-slot-definition) '%storage))))))
    (error "no direct slot for shared slot" (getf eslot :name))))

(defun description-slot-location (d name)
  (getf (find name (desc-eslots d) :key (lambda (s) (getf s :name))) :location))

(defvar *descriptions* '())

(defun list-all-descriptions () *descriptions*)

(defun fill-class-slots (d)
  (let* ((class (desc-class d))
         (metaclass (description (desc-metaclass d)))
         (direct-subclasses
           (loop for other in *descriptions*
                 when (member (desc-name d) (desc-supers other))
                   collect (desc-class other))))
    (set-instance-header class metaclass)
    (fill-slots class metaclass
                (list :name (desc-name d)
                      :direct-superclasses (mapcar (lambda (s) (desc-class s))
                                                   (description-supers d))
                      :direct-slots (desc-dslot-objects d)
                      :direct-default-initargs (desc-direct-default-initargs d)
                      :documentation (desc-documentation d))
                `((%unique-number . ,(desc-unique-number d))
                  (%precedence-list . ,(mapcar (lambda (c) (desc-class c)) (desc-cpl d)))
                  (%direct-subclasses . ,direct-subclasses)
                  ,@(if (built-in-description-p d)
                        '()
                        `((%effective-slots . ,(desc-eslot-objects d))
                          (%instance-size . ,(desc-instance-size d))
                          (%default-initargs . ,(desc-default-initargs d))
                          (%finalized-p . t)
                          (%dependents . ())))))
    (unless (built-in-description-p d)
      ;; The prototype; its slots stay unbound.
      (let ((prototype (%allocate class (+ (desc-instance-size d) 2) (desc-funcallable-p d))))
        (set-instance-header prototype d)
        (setf (%slot class '%prototype) prototype)))))

(defun build-braid ()
  (let ((descriptions (mapcar (lambda (record) (make-description (car record) (cdr record)))
                              (reverse *class-records*))))
    (setf *descriptions* descriptions)
    (setf *class-records* '())
    (build-classes descriptions)
    (setf *braid-built-p* t)
    (mapc #'funcall (reverse *deferred-definitions*))
    (setf *deferred-definitions* '())))

(defun early-define-class (name initargs)
  (when (get name '%description)
    (error "redefining a class is not supported yet" name))
  (let ((d (make-description name initargs)))
    (setf *descriptions* (append *descriptions* (list d)))
    (build-classes (list d))
    ;; Register the new class with its superclasses.
    (dolist (super (description-supers d))
      (let ((class (desc-class super)))
        (setf (%slot class '%direct-subclasses)
              (cons (desc-class d) (%slot class '%direct-subclasses)))))
    (desc-class d)))

(defun kiln.sys:%defclass (name &rest initargs)
  (cond (*switched-p*
         (apply #'mop-ensure-class name initargs))
        (*braid-built-p*
         (early-define-class name initargs))
        (t
         (push (cons name initargs) *class-records*)
         name)))

;;; Generic functions and methods

(defun required-parameters (lambda-list)
  (loop for p in lambda-list
        until (member p '(&optional &rest &key &aux &allow-other-keys))
        collect p))

(defun generic-function-p (object)
  (and (kiln.sys:%primop :funcallable-instance-p object)
       (member (find-class 'generic-function)
               (%slot (class-of object) '%precedence-list))))

(defun early-ensure-generic-function
    (name &key lambda-list argument-precedence-order
            (generic-function-class 'standard-generic-function)
            (method-class 'standard-method)
            (method-combination-name 'standard)
            (method-combination-arguments '())
            documentation)
  (declare (ignore method-combination-name method-combination-arguments))
  (let ((existing (and (fboundp name) (fdefinition name))))
    (if (generic-function-p existing)
        existing
        (let* ((required (required-parameters lambda-list))
               (gf (early-make-instance
                    generic-function-class
                    :name name
                    :lambda-list lambda-list
                    :argument-precedence-order (or argument-precedence-order required)
                    :specializer-profile (make-list (length required))
                    :declarations '()
                    :method-class (find-class method-class)
                    :documentation documentation)))
          (set-funcallable-instance-function
           gf (lambda (&rest arguments) (early-discriminate gf arguments)))
          (push gf *early-generic-functions*)
          (setf (fdefinition name) gf)
          gf))))

(defun ensure-generic-function+1 (name &rest initargs)
  (apply (if *switched-p* #'mop-ensure-generic-function #'early-ensure-generic-function)
         name initargs))

(defun kiln.sys:%defgeneric (name &rest initargs)
  (if *braid-built-p*
      (apply #'ensure-generic-function+1 name initargs)
      (progn (push (lambda () (apply #'early-ensure-generic-function name initargs))
                   *deferred-definitions*)
             name)))

(defvar *eql-specializers* '())

(defun intern-eql-specializer (object)
  (let ((entry (assoc object *eql-specializers*)))
    (if entry
        (cdr entry)
        (let ((specializer (make-instance 'eql-specializer :object object)))
          (push (cons object specializer) *eql-specializers*)
          specializer))))

(defun specializer-from-designator (designator)
  (cond ((symbolp designator) (find-class designator))
        ((and (consp designator) (eq (first designator) 'eql))
         (intern-eql-specializer (second designator)))
        (t designator)))

(defun congruent-lambda-list (method-lambda-list)
  ;; As Clostrophilia's COMPUTE-CONGRUENT-LAMBDA-LIST.
  (loop with result = '()
        for rest on method-lambda-list
        for p = (first rest)
        do (case p
             (&rest (push p result) (push (second rest) result)
              (when (member '&key rest) (push '&key result))
              (loop-finish))
             (&key (push p result) (loop-finish))
             (&optional (push p result))
             ((&aux &allow-other-keys) (loop-finish))
             (t (push (if (consp p) (first p) p) result)))
        finally (return (reverse result))))

(defun early-add-method (gf method)
  (let* ((specializers (%slot method '%specializers))
         (qualifiers (%slot method '%qualifiers))
         (methods (remove-if (lambda (m)
                               (and (equal (%slot m '%specializers) specializers)
                                    (null (set-exclusive-or (%slot m '%qualifiers) qualifiers))))
                             (%slot gf '%methods))))
    (setf (%slot gf '%methods) (cons method methods))
    (setf (%slot gf '%specializer-profile)
          (loop for specializer in specializers
                for p in (%slot gf '%specializer-profile)
                collect (if (eq specializer (find-class 't)) p t)))
    (setf (%slot method '%generic-function) gf)
    (dolist (specializer specializers)
      (setf (%slot specializer '%direct-methods)
            (cons method (%slot specializer '%direct-methods)))
      (unless (member gf (%slot specializer '%direct-generic-functions))
        (setf (%slot specializer '%direct-generic-functions)
              (cons gf (%slot specializer '%direct-generic-functions)))))
    method))

(defun early-ensure-method (name &key lambda-list qualifiers specializers documentation function
                                     fast-function)
  (let* ((gf (early-ensure-generic-function
              name :lambda-list (congruent-lambda-list lambda-list)))
         (method (early-make-instance (%slot gf '%method-class)
                                      :lambda-list lambda-list
                                      :qualifiers qualifiers
                                      :specializers (mapcar #'specializer-from-designator
                                                            specializers)
                                      :function function
                                      :fast-function fast-function
                                      :documentation documentation)))
    (early-add-method gf method)))

(defun kiln.sys:%defmethod (name &rest initargs)
  (if *braid-built-p*
      (apply (if *switched-p* #'mop-ensure-method #'early-ensure-method) name initargs)
      (progn (push (lambda () (apply #'early-ensure-method name initargs))
                   *deferred-definitions*)
             name)))

(defun kiln.sys:%method-function (method)
  ;; A next method is a method metaobject, or during the bootstrap a
  ;; function standing for the rest of the effective method.
  (if (functionp method)
      method
      (%slot method '%function)))

(defun kiln.sys:%method-fast-function (method)
  ;; NIL for the functions standing for the rest of an effective method.
  (if (functionp method)
      nil
      (%slot method '%fast-function)))

;;; Accessor methods of the braid's classes. The method functions read
;;; the slot by name, since its location can differ in subclasses.

(defun add-accessor-methods (class dslot)
  (let ((slot-name (%slot dslot '%name)))
    (dolist (reader (%slot dslot '%readers))
      (let ((gf (early-ensure-generic-function reader :lambda-list '(object))))
        (early-add-method
         gf (early-make-instance 'standard-reader-method
                                 :lambda-list '(object)
                                 :qualifiers '()
                                 :specializers (list class)
                                 :function (lambda (arguments next-methods)
                                             (declare (ignore next-methods))
                                             (early-slot-value (car arguments) slot-name))
                                 :slot-definition dslot))))
    (dolist (writer (%slot dslot '%writers))
      (let ((gf (early-ensure-generic-function writer :lambda-list '(new-value object))))
        (early-add-method
         gf (early-make-instance 'standard-writer-method
                                 :lambda-list '(new-value object)
                                 :qualifiers '()
                                 :specializers (list (find-class 't) class)
                                 :function (lambda (arguments next-methods)
                                             (declare (ignore next-methods))
                                             (setf (%slot (cadr arguments) slot-name)
                                                   (car arguments)))
                                 :slot-definition dslot))))))

(defun early-slot-value (object slot-name)
  (let ((value (%slot object slot-name)))
    (if (eq value +unbound-slot-value+)
        (error "unbound slot" slot-name object)
        value)))

;;; The early discriminating function

(defun specializer-applicable-p (specializer argument)
  (if (eq (class-of specializer) (find-class 'eql-specializer))
      (eql (%slot specializer '%object) argument)
      (member specializer (%slot (class-of argument) '%precedence-list))))

(defun early-method-more-specific-p (m1 m2 arguments)
  (loop for s1 in (%slot m1 '%specializers)
        for s2 in (%slot m2 '%specializers)
        for argument in arguments
        unless (eq s1 s2)
          return (cond ((eq (class-of s1) (find-class 'eql-specializer)) t)
                       ((eq (class-of s2) (find-class 'eql-specializer)) nil)
                       (t (let ((cpl (%slot (class-of argument) '%precedence-list)))
                            (< (position s1 cpl) (position s2 cpl)))))))

(defun call-method-function (method arguments next-methods)
  ;; Method functions with keyword parameters allow other keys
  ;; (lisp/macro-client.lisp).
  (funcall (%slot method '%function) arguments next-methods))

(defun early-discriminate (gf arguments)
  (let* ((applicable
           (loop for method in (%slot gf '%methods)
                 when (loop for specializer in (%slot method '%specializers)
                            for argument in arguments
                            always (specializer-applicable-p specializer argument))
                   collect method))
         (sorted (sort applicable (lambda (m1 m2) (early-method-more-specific-p m1 m2 arguments))))
         (around '()) (before '()) (primary '()) (after '()))
    (dolist (method sorted)
      (let ((qualifiers (%slot method '%qualifiers)))
        (cond ((null qualifiers) (push method primary))
              ((equal qualifiers '(:around)) (push method around))
              ((equal qualifiers '(:before)) (push method before))
              ((equal qualifiers '(:after)) (push method after))
              (t (error "unsupported method qualifiers" qualifiers)))))
    (setf around (nreverse around) before (nreverse before) primary (nreverse primary))
    (when (null primary)
      (error "no applicable method" (%slot gf '%name) arguments))
    (let ((main (lambda (arguments next-methods)
                  (declare (ignore next-methods))
                  (dolist (method before)
                    (call-method-function method arguments '()))
                  (multiple-value-prog1
                      (call-method-function (first primary) arguments (rest primary))
                    (dolist (method after)
                      (call-method-function method arguments '()))))))
      (if (null around)
          (funcall main arguments '())
          (call-method-function (first around) arguments
                                (append (rest around) (list main)))))))
