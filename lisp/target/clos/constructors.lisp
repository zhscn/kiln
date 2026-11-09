;;;; MAKE-INSTANCE without the generic protocol, for the common case.
;;;; For a class whose metaclass is STANDARD-CLASS and
;;;; whose instances get exactly the methods of ALLOCATE-INSTANCE,
;;;; INITIALIZE-INSTANCE and SHARED-INITIALIZE that a plain standard object
;;;; gets, MAKE-INSTANCE allocates the rack and fills the slots from the
;;;; class's initialization plan (PLANNED-SHARED-INITIALIZE, support.lisp)
;;;; directly: that is what those methods do, without three generic
;;;; function calls with &REST parameters and the defaulting of initargs
;;;; through ALLOCATE-INSTANCE-USING-CLASS. The decision is cached per
;;;; class (by its unique number, which a redefinition changes) and
;;;; forgotten when a method is added to or removed from one of the three
;;;; generic functions: the version of the initialization assumption.

(in-package #:clostrophilia)

;;; The initialization assumption (assumptions.lisp) is one cell for all
;;; classes: adding or removing a method of ALLOCATE-INSTANCE,
;;; INITIALIZE-INSTANCE or SHARED-INITIALIZE can apply to any class, so
;;; every class's cached answer goes out of date at once.
(defun construction-version ()
  (svref kiln.kernel::*initialization-assumption-cell* 0))

;;; Direct-mapped: (unique number, version, fast-p) per entry, indexed by
;;; the low bits of the unique number.
(defvar *construction-cache* (kiln.kernel::make-simple-vector (* 3 256) nil))

(defvar *standard-construction-methods* nil
  "(VERSION . method lists) of a plain standard object.")

(defun construction-methods (class prototype)
  (list (compute-applicable-methods #'allocate-instance (list class))
        (compute-applicable-methods #'initialize-instance (list prototype))
        (compute-applicable-methods #'shared-initialize (list prototype t))))

(defun standard-construction-methods ()
  (let ((entry *standard-construction-methods*)
        (version (construction-version)))
    (if (and entry (eql (car entry) version))
        (cdr entry)
        (let* ((class (find-class 'standard-object))
               (methods (construction-methods class (class-prototype class))))
          (setf *standard-construction-methods* (cons version methods))
          methods))))

(defvar *deciding-construction* nil)

(defun fast-construction-p (class)
  (and (eq (physical-class-of class) (find-class 'standard-class))
       (let ((standard (find-method-combination nil 'standard '())))
         (every (lambda (gf)
                  (eq (generic-function-method-combination gf) standard))
                (list #'allocate-instance #'initialize-instance #'shared-initialize)))
       (progn (unless (class-finalized-p class) (finalize-inheritance class)) t)
       (loop for a in (construction-methods class (class-prototype class))
             for b in (standard-construction-methods)
             always (and (= (length a) (length b)) (every #'eq a b)))))

(defun cached-fast-construction-p (class)
  (let* ((number (%slot class '%unique-number))
         (version (construction-version))
         (index (* 3 (kiln.sys:%primop :fixnum-logand number 255)))
         (cache *construction-cache*))
    (cond ((and (eql (svref cache index) number)
                (eql (svref cache (+ index 1)) version))
           (svref cache (+ index 2)))
          ;; Deciding needs MAKE-INSTANCE: those take the general way.
          (*deciding-construction* nil)
          (t
        (let ((fast-p (let ((*deciding-construction* t)) (fast-construction-p class))))
          ;; FAST-CONSTRUCTION-P may have finalized CLASS, which gives it
          ;; a new number; the version is the one read before deciding.
          (let* ((number (%slot class '%unique-number))
                 (index (* 3 (kiln.sys:%primop :fixnum-logand number 255))))
            (setf (svref cache index) nil
                  (svref cache (+ index 1)) version
                  (svref cache (+ index 2)) fast-p
                  (svref cache index) number))
          fast-p)))))

(define-condition invalid-initialization-arguments (program-error)
  ((%class :initarg :class :reader invalid-initargs-class)
   (%initargs :initarg :initargs :reader invalid-initargs))
  (:report (lambda (condition stream)
             (format stream "Invalid initialization arguments ~S for class ~S."
                     (invalid-initargs condition)
                     (class-name (invalid-initargs-class condition))))))

(defun check-initarg-shape (class initargs)
  (unless (evenp (length initargs))
    (error 'invalid-initialization-arguments :class class :initargs initargs)))

(defvar *valid-initargs-cache* (kiln.kernel::make-simple-vector (* 4 256) nil))

(defun initialization-argument-policy (class method-lists)
  (let ((keys nil) (allow-other-keys nil))
    (dolist (slot (class-slots class))
      (dolist (key (slot-definition-initargs slot))
        (pushnew (argument-key-name key) keys :test #'equal)))
    (dolist (methods method-lists)
      (dolist (method methods)
        (multiple-value-bind (required optional restp keyp method-keys allowp)
            (lambda-list-protocol (method-lambda-list method))
          (declare (ignore required optional restp keyp))
          (when allowp (setf allow-other-keys t))
          (dolist (key method-keys) (pushnew key keys :test #'equal)))))
    (values keys allow-other-keys)))

(defun valid-initialization-arguments (class)
  (let* ((number (%slot class '%unique-number))
         (version (construction-version))
         (index (* 4 (kiln.sys:%primop :fixnum-logand number 255)))
         (cache *valid-initargs-cache*))
    (when (and (eql number (svref cache index))
               (eql version (svref cache (+ index 1))))
      (return-from valid-initialization-arguments
        (values (svref cache (+ index 2)) (svref cache (+ index 3)))))
    (multiple-value-bind (keys allow-other-keys)
        (initialization-argument-policy class (construction-methods class (class-prototype class)))
      (when (and (eql number (%slot class '%unique-number))
                 (eql version (construction-version)))
        (setf (svref cache index) nil
              (svref cache (+ index 1)) version
              (svref cache (+ index 2)) keys
              (svref cache (+ index 3)) allow-other-keys
              (svref cache index) number))
      (values keys allow-other-keys))))

(defun check-initialization-keys (class initargs keys allow-other-keys)
  (unless (or allow-other-keys (getf initargs :allow-other-keys))
    (loop for (key nil) on initargs by #'cddr
          unless (or (eq key :allow-other-keys)
                     (and (symbolp key) (member (argument-key-name key) keys :test #'equal)))
            do (error 'invalid-initialization-arguments :class class :initargs initargs))))

(defun check-initialization-arguments (class initargs)
  (check-initarg-shape class initargs)
  (unless (getf initargs :allow-other-keys)
    (multiple-value-bind (keys allow-other-keys) (valid-initialization-arguments class)
      (check-initialization-keys class initargs keys allow-other-keys))))

(defmethod reinitialize-instance ((instance standard-object) &rest initargs)
  (when *check-initialization-arguments*
    (let ((class (physical-class-of instance)))
      (check-initarg-shape class initargs)
      (unless (getf initargs :allow-other-keys)
        (multiple-value-bind (keys allow-other-keys)
            (initialization-argument-policy
             class (list (compute-applicable-methods #'reinitialize-instance (list instance))
                         (compute-applicable-methods #'shared-initialize (list instance nil))))
          (check-initialization-keys class initargs keys allow-other-keys)))))
  (apply #'shared-initialize instance nil initargs)
  instance)

(defun construct-instance (class initargs)
  "What MAKE-INSTANCE does for a class with FAST-CONSTRUCTION-P."
  (when *check-initialization-arguments* (check-initarg-shape class initargs))
  (setf initargs (default-instance-initargs class initargs))
  (when *check-initialization-arguments* (check-initialization-arguments class initargs))
  (let ((instance (allocate-general-instance class (+ (%slot class '%instance-size) 2))))
    (setf (slot-value-using-location+1 instance -2) (%slot class '%unique-number)
          (slot-value-using-location+1 instance -1) (%slot class '%effective-slots))
    (planned-shared-initialize instance class t initargs)
    instance))

(defun forget-constructions (generic-function)
  (when (member (generic-function-name generic-function)
                '(allocate-instance initialize-instance shared-initialize))
    (kiln.kernel::change-assumption :initialization :all)))

(defun note-method-change (generic-function)
  "A method was added to or removed from GENERIC-FUNCTION."
  (kiln.kernel::defer-assumption-changes
   (lambda ()
     (unwind-protect
          (kiln.kernel::change-assumption :methods generic-function)
       (forget-constructions generic-function)))))

(defmethod add-method :after ((generic-function standard-generic-function) method)
  (declare (ignore method))
  (note-method-change generic-function))

(defmethod remove-method :after ((generic-function standard-generic-function) method)
  (declare (ignore method))
  (note-method-change generic-function))

(defmethod reinitialize-instance :around
    ((generic-function standard-generic-function) &rest initargs)
  (declare (ignore initargs))
  (kiln.kernel::defer-assumption-changes
   (lambda ()
     (unwind-protect (call-next-method)
       ;; Effective methods depend on method combination and argument order.
       (compute-and-set-specializer-profile generic-function)
       (setf (call-history generic-function) '())
       (invalidate-discriminating-function generic-function)
       (note-method-change generic-function)))))

(let ((gf (mop-make-instance
           'standard-generic-function
           :name 'make-instance
           :lambda-list '(class &rest initargs &key &allow-other-keys)
           :method-class (find-class 'standard-method)
           :method-combination (find-method-combination nil 'standard '()))))
  (setf (fdefinition 'make-instance) gf)
  (push gf *early-generic-functions*)
  (defmethod make-instance ((class symbol) &rest initargs)
    (apply #'make-instance (find-class class) initargs))
  (defmethod make-instance ((class class) &rest initargs)
    (apply #'mop-make-instance class initargs)))

(defgeneric no-next-method (generic-function method &rest args))
(defmethod no-next-method ((generic-function standard-generic-function)
                           (method standard-method) &rest args)
  (error "No next method for ~S in ~S with arguments ~S" method generic-function args))

(defgeneric function-keywords (method))
(defmethod function-keywords ((method standard-method))
  (let* ((ll (method-lambda-list method))
         (key-pos (position '&key ll)))
    (if key-pos
        (let ((keys '())
              (aok nil))
          (loop for spec in (subseq ll (+ key-pos 1))
                until (member spec '(&aux))
                do (cond ((eq spec '&allow-other-keys) (setf aok t))
                         ((symbolp spec) (push (intern (symbol-name spec) '#:keyword) keys))
                         ((consp spec)
                          (let ((var (first spec)))
                            (push (if (consp var)
                                      (first var)
                                      (intern (symbol-name var) '#:keyword))
                                  keys)))))
          (values (nreverse keys) aok))
        (values '() nil))))

(defgeneric describe-object (object stream))
(defmethod describe-object (object stream)
  (format stream "~&~S is an instance of ~S.~%" object (physical-class-of object)))
