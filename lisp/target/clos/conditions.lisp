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
           (if (member class (%slot (class-of object) '%precedence-list)) t nil))
          ((member type *types-without-objects*) nil)
          (t (kiln.kernel::unknown-type type)))))

(setf kiln.kernel::*class-typep* #'class-typep)

;;; (TYPEP OBJECT 'TYPE) at a call site with its CACHE (lower.lisp,
;;; LOWER-CACHED-TYPEP): when TYPE names a class (and is not a DEFTYPE),
;;; the result depends only on the object's class, so the car of CACHE
;;; keeps the stamp of the last object's class, doubled, plus 1 if the
;;; result was true. One word, written at once. A call site that sees
;;; objects of many classes (an AST walker) misses that cache: behind it
;;; is a direct-mapped cache of (key type) pairs for all call sites.
(defvar *typep-cache* (kiln.kernel::make-simple-vector (* 2 4096) nil))

(defun kiln.kernel::%typep-cached (object type cache)
  (let* ((stamp (stamp object))
         (key (+ stamp stamp))
         (entry (car cache)))
    (cond ((eq entry key) nil)
          ((eq entry (+ key 1)) t)
          (t
           (let* ((global *typep-cache*)
                  (index (* 2 (kiln.sys:%primop
                               :fixnum-logand
                               (kiln.sys:%primop :fixnum-logxor stamp
                                                 (kiln.sys:%primop :identity-hash type))
                               4095)))
                  (global-entry (svref global index)))
             (if (and (eq (svref global (+ index 1)) type)
                      (or (eq global-entry key) (eq global-entry (+ key 1))))
                 (progn (setf (car cache) global-entry)
                        (eq global-entry (+ key 1)))
                 (let ((result (if (typep object type) t nil)))
                   (when (and (null (get type 'kiln.kernel::type-expander))
                              (find-class type nil))
                     (let ((new (if result (+ key 1) key)))
                       (setf (car cache) new)
                       ;; The type first: a reader that sees the new key
                       ;; with the old type misses.
                       (setf (svref global (+ index 1)) nil
                             (svref global index) new
                             (svref global (+ index 1)) type)))
                   result)))))))

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
