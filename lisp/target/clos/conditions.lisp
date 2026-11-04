;;;; What Predicament expects from the implementation (docs/10 §10), as
;;;; SICL's Code/Conditions: the metaclass CONDITION-CLASS, the class
;;;; CONDITION, DEFINE-CONDITION and the condition maker. Also class names
;;;; as types for TYPEP, and the default debugger.

(in-package #:clostrophilia)

;;; TYPEP of a class name or a class.
(defun class-typep (object type)
  (let ((class (if (symbolp type) (find-class type nil) type)))
    (if (null class)
        (kiln.kernel::unknown-type type)
        (if (member class (%slot (class-of object) '%precedence-list)) t nil))))

(setf kiln.kernel::*class-typep* #'class-typep)

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

(defun write-string (string &optional stream &key (start 0) end)
  (declare (ignore stream))
  (print (subseq string start end))
  string)
