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
  (and (eq (class-of class) (find-class 'standard-class))
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

(defun construct-instance (class initargs)
  "What MAKE-INSTANCE does for a class with FAST-CONSTRUCTION-P."
  (let ((defaults (%slot class '%default-initargs)))
    (when defaults
      (loop with default = '(nil)
            for (name nil thunk) in defaults
            do (when (eq (getf initargs name default) default)
                 (setf initargs (append initargs (list name (funcall thunk))))))))
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
