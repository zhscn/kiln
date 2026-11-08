;;;; What Predicament expects from the implementation, as
;;;; SICL's Code/Conditions: the metaclass CONDITION-CLASS, the class
;;;; CONDITION, DEFINE-CONDITION and the condition maker. Also class names
;;;; as types for TYPEP, and the default debugger.

(in-package #:clostrophilia)

;;; Standard types that have no objects in kiln yet: nothing is of them.
(defparameter *types-without-objects*
  '())

;;; TYPEP of a class name or a class.
(defun class-typep (object type)
  (let ((class (if (symbolp type) (find-class type nil) type)))
    (cond (class
           (if (eq (class-of class) (find-class 'structure-class nil))
               (structure-layout-typep object (ensure-structure-layout class))
               (if (member class (%slot (class-of object) '%precedence-list)) t nil)))
          ((member type *types-without-objects*) nil)
          (t (kiln.kernel::unknown-type type)))))

(setf kiln.kernel::*class-typep* #'class-typep)

;;; Types whose TYPEP depends only on the object's class (as given by its
;;; stamp), so that the result can be cached by stamp:
;;; - symbols that TYPEP handles by a predicate that holds for all the
;;;   objects of a built-in class or none (*CLASS-DETERMINED-TYPES*), not
;;;   the others it handles by a predicate (*CLASS-UNDETERMINED-TYPES*:
;;;   KEYWORD or BIT are not classes, and a string or vector type covers
;;;   only the native objects of its class);
;;; - other symbols that name a class and are not DEFTYPEs: TYPEP is
;;;   CLASS-TYPEP, membership in the class precedence list;
;;; - (OR ...), (AND ...) and (NOT ...) of those.
;;; The answers hold until a type, a class name or a class precedence list
;;; changes; KILN.KERNEL::INVALIDATE-TYPE-CACHES then empties the caches.
;;; A redefined class gets a new unique number, but its obsolete instances
;;; keep the old one as their stamp until they are updated, so that the
;;; cache is emptied then too (REFINALIZE).
(defparameter *class-determined-types*
  '(t nil null symbol cons list atom function compiled-function character
    number real rational integer fixnum bignum ratio float single-float
    short-float double-float long-float complex))

(defparameter *class-undetermined-types*
  '(keyword boolean base-char standard-char string base-string simple-string
    simple-base-string simple-vector vector simple-array simple-bit-vector array
    sequence bit unsigned-byte signed-byte))

(defun class-determined-type-p (type)
  (cond ((symbolp type)
         (or (and (member type *class-determined-types*) t)
             (and (not (member type *class-undetermined-types*))
                  (null (get type 'kiln.kernel::type-expander))
                  (find-class type nil)
                  t)))
        ((consp type)
         (case (car type)
           ((or and) (loop for x in (cdr type) always (class-determined-type-p x)))
           (not (and (consp (cdr type)) (null (cddr type))
                     (class-determined-type-p (cadr type))))
           (t nil)))
        (t nil)))

(defun cacheable-type-p (type)
  "CLASS-DETERMINED-TYPE-P, remembering the types that are not."
  (let* ((memo kiln.kernel::*uncacheable-types*)
         (index (kiln.sys:%primop :fixnum-logand
                                  (kiln.sys:%primop :identity-hash type) 511)))
    (cond ((eq (svref memo index) type) nil)
          ((class-determined-type-p type) t)
          (t (setf (svref memo index) type)
             nil))))

(declaim (inline typep-cache-index typep-cache-probe))

(defun typep-cache-index (stamp type)
  (* 2 (kiln.sys:%primop
        :fixnum-logand
        (kiln.sys:%primop :fixnum-logxor stamp (kiln.sys:%primop :identity-hash type))
        4095)))

(defun typep-cache-probe (stamp type)
  "The entry of KILN.KERNEL::*TYPEP-CACHE* for objects with STAMP and TYPE:
the stamp, doubled, plus 1 if the objects are of TYPE; NIL if there is
none."
  (let* ((cache kiln.kernel::*typep-cache*)
         (index (typep-cache-index stamp type))
         (entry (svref cache index))
         (key (+ stamp stamp)))
    (and (eq (svref cache (+ index 1)) type)
         (or (eq entry key) (eq entry (+ key 1)))
         entry)))

(defun typep-cache-fill (object type stamp)
  "Computes (TYPEP OBJECT TYPE) and, if TYPE depends on the class alone,
stores it in KILN.KERNEL::*TYPEP-CACHE* under STAMP. Returns the entry,
or T or NIL for a type that is not cached."
  (let ((result (kiln.kernel::uncached-typep object type)))
    (if (cacheable-type-p type)
        (let* ((cache kiln.kernel::*typep-cache*)
               (index (typep-cache-index stamp type))
               (new (if result (+ stamp stamp 1) (+ stamp stamp))))
          ;; The type first: a reader that sees the new key with the old
          ;; type misses.
          (setf (svref cache (+ index 1)) nil
                (svref cache index) new
                (svref cache (+ index 1)) type)
          new)
        (if result t nil))))

(defun kiln.kernel::%cached-typep (object type)
  (let* ((stamp (stamp object))
         (entry (or (typep-cache-probe stamp type)
                    (typep-cache-fill object type stamp))))
    (if (kiln.kernel::fixnump entry)
        (eq entry (+ stamp stamp 1))
        entry)))

;;; Is SUPER in the class precedence list of the finalized CLASS? The
;;; answer for TYPEP of CLASS's instances and SUPER as the type.
(defun subclass-cached-p (class super)
  (let* ((number (%slot class '%unique-number))
         (entry (typep-cache-probe number super)))
    (if entry
        (eq entry (+ number number 1))
        (let ((result (if (member super (%slot class '%precedence-list)) t nil))
              (cache kiln.kernel::*typep-cache*)
              (index (typep-cache-index number super)))
          (setf (svref cache (+ index 1)) nil
                (svref cache index) (if result (+ number number 1) (+ number number))
                (svref cache (+ index 1)) super)
          result))))

;;; (TYPEP OBJECT 'TYPE) at a call site with its CACHE (lower.lisp,
;;; LOWER-CACHED-TYPEP), TYPE a symbol: when it names a class (and is not a
;;; DEFTYPE), the result depends only on the object's class, so the car of
;;; CACHE keeps the entry of KILN.KERNEL::*TYPEP-CACHE* for the last
;;; object's class. One word, written at once. A call site that sees
;;; objects of many classes (an AST walker) misses that cache and finds
;;; the entry in the global cache.
(defun kiln.kernel::%typep-cached (object type cache)
  (let* ((stamp (stamp object))
         (key (+ stamp stamp))
         (entry (car cache)))
    (cond ((eq entry key) nil)
          ((eq entry (+ key 1)) t)
          (t
           (let ((entry (or (typep-cache-probe stamp type)
                            (typep-cache-fill object type stamp))))
             (if (kiln.kernel::fixnump entry)
                 (progn (setf (car cache) entry)
                        (eq entry (+ key 1)))
                 entry))))))

;;; Condition classes are standard classes of their own metaclass, so
;;; that conditions can be told apart by their class's class.
(defclass condition-class (standard-class)
  ())

(defclass condition (standard-object)
  ((%report :initform nil :initarg :report :reader condition-report))
  (:metaclass condition-class))

(defmacro define-condition (name (&rest supertypes) direct-slots &rest options)
  (let* ((report-option (find :report options :key #'car))
         (default-initargs-option (find :default-initargs options :key #'car))
         (other-options (remove default-initargs-option (remove report-option options))))
    `(progn
       (defclass ,name ,(or supertypes '(condition))
         ,direct-slots
         (:metaclass condition-class)
         ,@(if (or report-option default-initargs-option)
               `((:default-initargs
                  ,@(if report-option
                        `(:report ,(let ((report (second report-option)))
                                     (if (stringp report)
                                         `(lambda (condition stream)
                                            (declare (ignore condition))
                                            (write-string ,report stream))
                                         `(function ,report))))
                        '())
                  ,@(rest default-initargs-option)))
               '())
         ,@other-options)
       ',name)))

(defun kiln-make-condition (type &rest initargs)
  (let ((class (if (symbolp type) (find-class type) type)))
    (unless (eq (class-of class) (find-class 'condition-class))
      (kiln.kernel::unknown-type type))
    (apply #'make-instance class initargs)))

(defvar predicament::*condition-maker* 'kiln-make-condition)

;;; The default debugger, until there are streams and a REPL: the program
;;; ends with a message naming the condition and its slots (the format
;;; control and arguments for a simple condition).
(defun kiln-default-debugger (condition)
  (%primop-lisp-error
   (cons (class-name (class-of condition))
         (loop for slot in (%slot (class-of condition) '%effective-slots)
               for name = (%slot slot '%name)
               unless (eq name '%report)
                 append (list name (debugger-description (%slot condition name)))))))

(defun debugger-description (object)
  ;; Without a printer, name generic functions and instances by class.
  (cond ((generic-function-p object)
         (list 'generic-function (%slot object '%name)))
        ((instancep object)
         (list 'instance-of (class-name (class-of object))))
        ((consp object)
         (mapcar #'debugger-description object))
        (t object)))

(defun %primop-lisp-error (list)
  (kiln.sys:%primop :lisp-error list))

(defvar predicament::*default-debugger* 'kiln-default-debugger)

;;; WRITE-STRING (for string reports) is Cyclosis' (streams.lisp).
