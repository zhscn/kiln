;;;; EVAL, COMPILE and LOAD at run time (docs/11 §2.1): Maclina compiles to
;;;; bytecode and runs it in its VM, in kiln's global environment. kiln's
;;;; Trucler client describes that environment; it is a Trucler "native"
;;;; client, for which Maclina's native VM (vm-native.lisp) is written.

(defpackage #:kiln.eval
  (:use #:common-lisp)
  (:local-nicknames (#:m #:maclina.machine)
                    (#:mc #:maclina.compile))
  (:export #:client))

(in-package #:kiln.eval)

(defclass client (trucler-native:client) ())

;;; The global environment is NIL. Special variables are recorded on the
;;; plist by PROCLAIM, constants by DEFCONSTANT (the kernel).

;;; The bytecode is kept in a simple vector: an (UNSIGNED-BYTE 8) array is a
;;; Regalia instance, whose AREF goes through generic functions; the VM
;;; reads the bytecode at each instruction.
(defmethod m:make-module ((client client) bytecode)
  (make-instance 'm:module :bytecode (coerce bytecode 'simple-vector)))

(defmethod trucler:describe-variable ((client client) (env null) name)
  (cond ((or (null name) (eq name t) (keywordp name) (get name 'kiln.kernel::constant))
         (make-instance 'trucler:constant-variable-description
           :name name :value (symbol-value name)))
        ((get name 'kiln.kernel::special)
         (make-instance 'trucler:global-special-variable-description :name name))
        (t nil)))

(defmethod trucler:describe-function ((client client) (env null) name)
  (cond ((and (symbolp name) (special-operator-p name))
         (make-instance 'trucler:special-operator-description :name name))
        ((and (symbolp name) (macro-function name))
         (make-instance 'trucler:global-macro-description
           :name name :expander (macro-function name)))
        ((fboundp name)
         (make-instance 'trucler:global-function-description :name name))
        (t nil)))

(defmethod trucler:describe-block ((client client) (env null) name)
  (declare (ignore name))
  nil)

(defmethod trucler:describe-tag ((client client) (env null) name)
  (declare (ignore name))
  nil)

(defmethod trucler:describe-declarations ((client client) (env null))
  (make-instance 'trucler:declarations-description :declarations '()))

;;; The macro functions of Maclina's lexical environments, for
;;; MACRO-FUNCTION and MACROEXPAND with an environment (the kernel).
(setf kiln.kernel::*environment-macro-function*
      (lambda (name environment)
        (let ((description (trucler:describe-function m:*client* environment name)))
          (and (typep description 'trucler:macro-description)
               (trucler:expander description)))))

(setf m:*client* (make-instance 'client))
(maclina.vm-native:initialize-vm 100000)

(in-package #:kiln.kernel)

(defvar *load-verbose* nil)
(defvar *load-print* nil)
(defvar *load-pathname* nil)
(defvar *load-truename* nil)

;;; Calls of unknown functions are reported after the form has run, if the
;;; functions are still undefined: not for a recursive DEFUN.
(defun eval (form)
  (let ((unknown '()))
    (multiple-value-prog1
        (handler-bind ((maclina.compile:unknown-function
                         (lambda (condition)
                           (push condition unknown)
                           (muffle-warning condition))))
          (maclina.compile:eval form nil))
      (dolist (condition (reverse unknown))
        (unless (fboundp (maclina.compile:name condition))
          (warn condition))))))

(defun compile (name &optional definition)
  (let ((function (cond ((functionp definition) definition)
                        (definition (maclina.compile:compile definition nil))
                        (t (let ((f (fdefinition name)))
                             (if (functionp f) f (maclina.compile:compile f nil)))))))
    (when name
      (if (and (symbolp name) (macro-function name) (null definition))
          (setf (macro-function name) function)
          (setf (fdefinition name) function)))
    (values (or name function) nil nil)))

(defun load (filespec &key (verbose *load-verbose*) (print *load-print*)
                           (if-does-not-exist t) (external-format :default))
  (declare (ignore external-format))
  (with-open-file (stream filespec :if-does-not-exist (if if-does-not-exist :error nil))
    (when stream
      (when verbose
        (format t "~&; loading ~A~%" filespec))
      (let ((*package* *package*)
            (*readtable* *readtable*)
            (*load-pathname* (pathname filespec))
            (*load-truename* (pathname filespec))
            (eof (list nil)))
        (loop for form = (read stream nil eof)
              until (eq form eof)
              do (let ((values (multiple-value-list (eval form))))
                   (when print
                     (format t "~&~{~S~^ ~}~%" values)))))
      t)))
