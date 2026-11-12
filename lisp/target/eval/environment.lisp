;;;; Image global queries and lexical macro environment hooks.

(defpackage #:kiln.eval
  (:use #:common-lisp)
  (:export #:client #:environment-client))

(in-package #:kiln.eval)

(defclass client () ())

(defvar *global-client* (make-instance 'client))

;;; The global environment is NIL. Special variables are recorded on the
;;; plist by PROCLAIM, constants by DEFCONSTANT (the kernel).

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
           :name name :expander (macro-function name) :compiler-macro (compiler-macro-function name)
           :inline (kiln.kernel::function-inline-declaration name)))
        ((fboundp name)
         (make-instance 'trucler:global-function-description :name name
                        :compiler-macro (compiler-macro-function name)
                        :inline (kiln.kernel::function-inline-declaration name)))
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
;;; that made them, including HIR and reference environments.
(defgeneric environment-client (environment)
  (:method (environment)
    (declare (ignore environment))
    *global-client*))

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

(setf kiln.kernel::*environment-compiler-macro-function*
      (lambda (name environment)
        (let ((description (trucler:describe-function
                            (environment-client environment) environment name)))
          (when (or (null description)
                    (typep description '(or trucler:global-function-description trucler:global-macro-description)))
            (compiler-macro-function name)))))

