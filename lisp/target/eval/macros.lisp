;;;; The standard macros at run time (docs/11 §3): what Common-macros
;;;; leaves to its client.

(in-package #:kiln.kernel)

(dolist (entry *kiln-macros*)
  (setf (macro-function (car entry)) (cdr entry)))

(setf kiln.cmd:*client* (make-instance 'kiln.macros-target:macro-client))

;;; DEFPACKAGE as at compile time (front.lisp).
(defmacro defpackage (name &rest options)
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (%defpackage ',name ',options)))

;;; Places: expanders recorded by DEFINE-SETF-EXPANDER and DEFSETF
;;; (%DEFINE-SETF-EXPANDER, the kernel), then macros, then the SETF
;;; function.
(defmethod kiln.cmd:get-setf-expansion
    ((client kiln.macros-target:macro-client) place &optional environment)
  (if (and (consp place) (symbolp (car place)))
      (let ((expander (get (car place) 'setf-expander)))
        (if expander
            (funcall expander place environment)
            (multiple-value-bind (expansion macrop) (macroexpand-1 place environment)
              (if macrop
                  (kiln.cmd:get-setf-expansion client expansion environment)
                  (call-next-method)))))
      (call-next-method)))

(defun get-setf-expansion (place &optional environment)
  (kiln.cmd:get-setf-expansion kiln.cmd:*client* place environment))
