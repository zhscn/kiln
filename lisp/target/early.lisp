;;;; Early stand-ins for the condition system and FORMAT (docs/10 §7).
;;;;
;;;; Predicament (conditions) and Invistra (FORMAT) need CLOS, and CLOS
;;;; needs ERROR and FORMAT, so until they are loaded:
;;;;
;;;; - ERROR terminates the program with a message built from its
;;;;   arguments; WARN prints them and returns.
;;;; - FORMAT with destination NIL returns the control string itself.
;;;; - DEFINE-CONDITION records the definition in *EARLY-CONDITION-TYPES*
;;;;   (initforms and the :REPORT option as functions), for the condition
;;;;   system to define the classes once it is loaded.

(in-package #:kiln.kernel)

;;; Documentation strings of names, kept on the symbol's plist (of the
;;; second element for (SETF NAME)) under the documentation type. Other
;;; objects have none until CLOS takes over DOCUMENTATION.
;;; Compiler macros are recorded (on the plist of the name, or of the
;;; second element of (SETF NAME)) but not used yet: the compiler does not
;;; call them.
(defun compiler-macro-function (name &optional environment)
  (declare (ignore environment))
  (if (consp name)
      (get (second name) 'setf-compiler-macro)
      (get name 'compiler-macro)))

(defun (setf compiler-macro-function) (function name &optional environment)
  (declare (ignore environment))
  (if (consp name)
      (setf (get (second name) 'setf-compiler-macro) function)
      (setf (get name 'compiler-macro) function)))

(defun documentation-symbol (x)
  (if (consp x) (second x) x))

(defun documentation (x doc-type)
  (if (or (symbolp x) (consp x))
      (getf (get (documentation-symbol x) 'documentation) doc-type)
      nil))

(defun (setf documentation) (new-value x doc-type)
  (when (or (symbolp x) (consp x))
    (let* ((symbol (documentation-symbol x))
           (plist (get symbol 'documentation)))
      (setf (get symbol 'documentation) (list* doc-type new-value plist))))
  new-value)

(defun error (datum &rest arguments)
  (%primop :lisp-error (cons datum arguments)))

(defun cerror (continue-string datum &rest arguments)
  (declare (ignore continue-string))
  (apply #'error datum arguments))

(defun warn (datum &rest arguments)
  (print (list* 'warning datum arguments))
  nil)

(defun format (destination control-string &rest arguments)
  (if (null destination)
      control-string
      (progn (print (cons control-string arguments)) nil)))

(defmacro assert (test-form &optional places datum &rest arguments)
  (declare (ignore places))
  `(unless ,test-form
     ,(if datum
          `(error ,datum ,@arguments)
          `(error "assertion failed" ',test-form))))

(defvar *early-condition-types* '()
  "Definitions made by DEFINE-CONDITION before the condition system is
loaded, most recent first. Each is (NAME SUPERS SLOTS OPTIONS) where a
slot is a property list as in a canonicalized DEFCLASS slot.")

(defun early-define-condition (name supers slots options)
  (push (list name supers slots options) *early-condition-types*)
  name)

(defmacro define-condition (name supers slot-specs &rest options)
  (flet ((slot-form (spec)
           (if (symbolp spec)
               `(list :name ',spec)
               (let ((plist (cdr spec)) (initargs '()) (readers '()) (writers '())
                     (rest '()))
                 (do ((p plist (cddr p))) ((null p))
                   (let ((key (car p)) (value (cadr p)))
                     (case key
                       (:initarg (push value initargs))
                       (:reader (push value readers))
                       (:writer (push value writers))
                       (:accessor (push value readers) (push `(setf ,value) writers))
                       (:initform
                        (setf rest (append rest `(:initform ',value
                                                  :initfunction (lambda () ,value)))))
                       (t (setf rest (append rest `(,key ',value)))))))
                 `(list :name ',(car spec)
                        :initargs ',(reverse initargs)
                        :readers ',(reverse readers)
                        :writers ',(reverse writers)
                        ,@rest))))
         (option-form (option)
           (case (car option)
             (:report
              (let ((report (cadr option)))
                `(list :report ,(if (stringp report)
                                    report
                                    `(function ,report)))))
             (:default-initargs
              `(list :default-initargs
                     (list ,@(do ((p (cdr option) (cddr p)) (forms '()))
                                 ((null p) (reverse forms))
                               (push `(list ',(car p) ',(cadr p) (lambda () ,(cadr p)))
                                     forms)))))
             (t `',option))))
    `(early-define-condition
      ',name ',supers
      (list ,@(mapcar #'slot-form slot-specs))
      (list ,@(mapcar #'option-form options)))))

;;; The standard stream variables, NIL until there are streams (Cyclosis).
(defvar *standard-input* nil)
(defvar *standard-output* nil)
(defvar *error-output* nil)
(defvar *trace-output* nil)
(defvar *terminal-io* nil)
(defvar *debug-io* nil)
(defvar *query-io* nil)
