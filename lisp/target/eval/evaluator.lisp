;;;; EVAL, COMPILE and LOAD at run time: Maclina compiles to
;;;; bytecode and runs it in its VM, in kiln's global environment. kiln's
;;;; Trucler client describes that environment; it is a Trucler "native"
;;;; client, for which Maclina's native VM (vm-native.lisp) is written.

(defpackage #:kiln.eval
  (:use #:common-lisp)
  (:local-nicknames (#:m #:maclina.machine)
                    (#:mc #:maclina.compile))
  (:export #:client #:environment-client))

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
  (cond ((or (null name) (eq name t) (keywordp name) (get name 'kiln.kernel::%constant))
         (make-instance 'trucler:constant-variable-description
           :name name :value (symbol-value name)))
        ((get name 'kiln.kernel::%special)
         (make-instance 'trucler:global-special-variable-description :name name))
        ((kiln.kernel::%has-property name 'kiln.kernel::%symbol-macro)
         (make-instance 'trucler:global-symbol-macro-description
           :name name :expansion (kiln.kernel::%get name 'kiln.kernel::%symbol-macro)))
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
  (make-instance 'trucler:declarations-description :declarations kiln.kernel::*declaration-names*))

;;; The macro functions of lexical environments, for MACRO-FUNCTION and
;;; MACROEXPAND with an environment (the kernel). Environments are Trucler
;;; environments, queried with the client of the evaluator or compiler
;;; that made them: Maclina's (here), the reference client (the compiler
;;; module).
(defgeneric environment-client (environment)
  (:method (environment)
    (declare (ignore environment))
    m:*client*))

(setf kiln.kernel::*environment-macro-function*
      (lambda (name environment)
        (let ((description (trucler:describe-function
                            (environment-client environment) environment name)))
          (and (typep description 'trucler:macro-description)
               (trucler:expander description)))))

(setf kiln.kernel::*environment-symbol-macro*
      (lambda (name environment)
        (let ((description (trucler:describe-variable
                            (environment-client environment) environment name)))
          (if (typep description 'trucler:symbol-macro-description)
              (values (trucler:expansion description) t)
              (values nil nil)))))

(setf m:*client* (make-instance 'client))
(maclina.vm-native:initialize-vm 100000)

(in-package #:kiln.kernel)

(setf *compiled-function-instance-p*
      (lambda (object)
        (or (typep object 'maclina.machine:function)
            (typep object 'maclina.machine:closure))))


(defvar *load-verbose* nil)
(defvar *load-print* nil)
(defvar *load-pathname* nil)
(defvar *load-truename* nil)

(defvar *eval-function* nil
  "The function EVAL evaluates a form with: the compiler module sets it to
its native evaluator; NIL, Maclina's.")

(defun eval (form)
  (if *eval-function*
      (funcall *eval-function* form)
      (maclina-eval form)))

;;; Calls of unknown functions are reported after the form has run, if the
;;; functions are still undefined: not for a recursive DEFUN.
(defun maclina-eval (form)
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

(defvar *compile-function* nil
  "The function COMPILE compiles a lambda expression with: the compiler
module sets it to its native compiler; NIL, Maclina's
bytecode compiler.")

(defun compile-lambda (definition)
  (if *compile-function*
      (funcall *compile-function* definition)
      (maclina.compile:compile definition nil)))

(defun compile (name &optional definition)
  (let ((function (cond ((functionp definition) definition)
                        (definition (compile-lambda definition))
                        (t (let ((f (fdefinition name)))
                             (if (functionp f) f (compile-lambda f)))))))
    (when name
      (if (and (symbolp name) (macro-function name) (null definition))
          (setf (macro-function name) function)
          (setf (fdefinition name) function)))
    (values (or name function) nil nil)))

(defun load (filespec &key (verbose *load-verbose*) (print *load-print*)
                           (if-does-not-exist t) (external-format :default))
  (labels ((load-stream (stream pathname truename binaryp)
             (let ((*package* *package*)
                   (*readtable* *readtable*)
                   (*load-pathname* pathname)
                   (*load-truename* truename)
                   (*load-print* print))
               (when (and verbose (not pathname))
                 (format t "~&; loading from stream~%"))
               (if binaryp
                   (maclina.load:load-bytecode-stream stream :verbose verbose)
                   (loop with eof = (list nil)
                         for form = (read stream nil eof)
                         until (eq form eof)
                         do (let ((values (multiple-value-list (eval form))))
                              (when print
                                (format t "~&~{~S~^ ~}~%" values))))))
             t)
           (fasl-stream-p (stream)
             (let ((magic 0))
               (dotimes (i 4)
                 (let ((byte (read-byte stream nil nil)))
                   (unless byte (return-from fasl-stream-p nil))
                   (setf magic (logior (ash magic 8) byte))))
               (= magic #x8d7498b1))))
    (if (streamp filespec)
        (load-stream filespec nil nil
                     (subtypep (stream-element-type filespec) '(unsigned-byte 8)))
        (let* ((merged (merge-pathnames filespec))
               (truename nil))
          (with-open-file (stream merged :element-type '(unsigned-byte 8)
                                        :if-does-not-exist (if if-does-not-exist :error nil))
            (unless stream (return-from load nil))
            (setf truename (truename merged))
            (when verbose (format t "~&; loading ~A~%" merged))
            (when (fasl-stream-p stream)
              (file-position stream 0)
              (return-from load (load-stream stream merged truename t))))
          (with-open-file (stream merged :external-format external-format)
            (load-stream stream merged truename nil))))))
