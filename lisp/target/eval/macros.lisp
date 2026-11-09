;;;; The standard macros at run time: what Common-macros
;;;; leaves to its client.

(in-package #:kiln.kernel)

;;; Common-macros' definitions of the standard macros, before kiln's own
;;; replace some of them: the compile-time environment of a cross
;;; compilation starts with these, as the host's does with
;;; COMMON-MACRO-DEFINITIONS' (lisp/cross.lisp).
(defvar *common-macros*
  (let ((macros '()))
    (do-external-symbols (s '#:common-lisp)
      (let ((f (macro-function s)))
        (when (and f (not (eq f (cdr (assoc s *kiln-macros*)))))
          (push (cons s f) macros))))
    macros))

(dolist (entry *kiln-macros*)
  (setf (macro-function (car entry)) (cdr entry)))

(defvar *runtime-macro-client* (make-instance 'kiln.macros-target:macro-client))
(setf kiln.cmd:*client* *runtime-macro-client*)

;;; DEFPACKAGE as at compile time (front.lisp).
(defmacro defpackage (name &rest options)
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (%defpackage ',name ',options)))

;;; Places: expanders recorded by DEFINE-SETF-EXPANDER and DEFSETF
;;; (%DEFINE-SETF-EXPANDER, the kernel), then macros, then the SETF
;;; function.
(defmethod kiln.cmd:get-setf-expansion
    ((client kiln.macros-target:macro-client) place &optional environment)
  (cond ((and (consp place) (symbolp (car place)))
         (let ((expander (if (and (eq (car place) 'the) (consp (cdr place)) (consp (cddr place))
                                  (null (cdddr place)))
                             ;; (SETF (THE type place) form) is (SETF place
                             ;; (THE type form)) (CLHS 5.1.2.6).
                             (lambda (place environment)
                               (multiple-value-bind (temps vals stores store-form access-form)
                                   (kiln.cmd:get-setf-expansion client (third place) environment)
                                 (values temps vals stores
                                         `(let ((,(first stores) (the ,(second place) ,(first stores))))
                                            ,store-form)
                                         `(the ,(second place) ,access-form))))
                             (get (car place) 'setf-expander))))
           (if expander
               (funcall expander place environment)
               (multiple-value-bind (expansion macrop) (macroexpand-1 place environment)
                 (if macrop
                     (kiln.cmd:get-setf-expansion client expansion environment)
                     (call-next-method))))))
        ((symbolp place)
         (multiple-value-bind (expansion macrop) (macroexpand-1 place environment)
           (if macrop
               (kiln.cmd:get-setf-expansion client expansion environment)
               (call-next-method))))
        (t
         (call-next-method))))

(defun get-setf-expansion (place &optional environment)
  (kiln.cmd:get-setf-expansion kiln.cmd:*client* place environment))
