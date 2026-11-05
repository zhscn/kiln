;;;; Compiling in the running image (docs/11 §8, M5.3): IMAGE-CLIENT. Loaded
;;;; after front.lisp and cross.lisp. The compile-time environment is the run-time one,
;;;; as in other implementations: macros, special variables and constants
;;;; are the global environment's, and the code evaluated at compile time
;;;; (EVAL-WHEN, DEFMACRO, the proclamations of DEFVAR) runs in Maclina's VM
;;;; (the eval module), so its definitions take effect in the running image.
;;;; What the host's front end knew when it compiled the modules loaded
;;;; before the compiler (inline functions) comes from session.lisp.

(in-package #:kiln.compiler)

(defclass image-client (client) ())

(defmethod cb:convert-with-ordinary-macro-p ((client image-client) operator)
  (declare (ignore operator))
  nil)

(defmethod run-time-packages-p ((client image-client))
  t)

;;; Places: a symbol macro of the lexical environment, else as at run time
;;; (lisp/target/eval/macros.lisp).
(defmethod kiln.cmd:get-setf-expansion ((client image-client) place &optional environment)
  (let ((environment (or environment *environment*)))
    (multiple-value-bind (expansion macrop) (symbol-macro-expansion client environment place)
      (if macrop
          (kiln.cmd:get-setf-expansion client expansion environment)
          (call-next-method client place environment)))))

;;; The global environment, for Trucler: described as Maclina's client
;;; describes it (lisp/target/eval/evaluator.lisp), whatever the client.
;;; MACRO-FUNCTION with a Common-boot environment queries it with a
;;; reference client (environment.lisp).

(defclass run-time-environment () ())

(defvar *run-time-environment* (make-instance 'run-time-environment))

(defmethod trucler:global-environment (client (environment run-time-environment))
  (declare (ignore client))
  environment)

(defmethod trucler:describe-variable (client (environment run-time-environment) name)
  (declare (ignore client))
  (trucler:describe-variable maclina.machine:*client* nil name))

(defmethod trucler:describe-function (client (environment run-time-environment) name)
  (declare (ignore client))
  (trucler:describe-function maclina.machine:*client* nil name))

(defmethod trucler:describe-block (client (environment run-time-environment) name)
  (declare (ignore client name))
  nil)

(defmethod trucler:describe-tag (client (environment run-time-environment) tag)
  (declare (ignore client tag))
  nil)

(defmethod trucler:describe-declarations (client (environment run-time-environment))
  (declare (ignore client))
  (make-instance 'trucler:declarations-description :declarations '()))

;;; As Clostrum's environments with no OPTIMIZE proclamation (the host's).
(defmethod trucler:describe-optimize (client (environment run-time-environment))
  (declare (ignore client))
  (make-instance 'trucler:optimize-description
    :speed 3 :debug 3 :space 3 :safety 3 :compilation-speed 3))

(defmethod make-compile-environment ((client image-client))
  (make-instance 'trucler-reference:environment
    :global-environment *run-time-environment*))

;;; Compile-time evaluation: Maclina, in an environment with the local
;;; macros and symbol macros of the Trucler environment (MACROLET and
;;; SYMBOL-MACROLET at top level); the rest of a lexical environment is
;;; not visible to code evaluated at compile time.

(defun maclina-environment (environment)
  (let ((env nil))
    (flet ((lexenv ()
             (or env (setf env (maclina.compile::make-null-lexical-environment nil)))))
      (dolist (d (reverse (trucler-reference::function-description environment)))
        (when (typep d 'trucler:local-macro-description)
          (setf env (trucler:add-local-macro maclina.machine:*client* (lexenv)
                                             (trucler:name d) (trucler:expander d)))))
      (dolist (d (reverse (trucler-reference::variable-description environment)))
        (when (typep d 'trucler:local-symbol-macro-description)
          (setf env (trucler:add-local-symbol-macro maclina.machine:*client* (lexenv)
                                                    (trucler:name d) (trucler:expansion d))))))
    env))

(defmethod cb:eval-cst ((client image-client) cst environment)
  (maclina.compile:eval (cst:raw cst) (maclina-environment environment)))

(defmethod cb:compile-local-macro-function-ast ((client image-client) lambda-ast environment)
  (declare (ignore lambda-ast environment))
  (error "The compiler on kiln does not compile MACROLET not at top level yet (docs/11 §8)."))

;;; Inline proclamations at compile time (DECLAIM) reach the front end
;;; through the kernel's PROCLAIM.
(setf kiln.kernel::*proclaim-hook*
      (lambda (declaration)
        (when (and (boundp '*client*) (typep *client* 'image-client)
                   (consp declaration) (member (first declaration) '(inline notinline)))
          (note-inline-proclamation (first declaration) (rest declaration)))))

(defvar *host-inline-functions*)        ; session.lisp

(defmethod initialize-session ((client image-client) session)
  ;; The packages of the image exist at run time (a symbol table's use
  ;; lists name only those, lower.lisp).
  (setf (session-packages session) (list-all-packages))
  (loop for (name . entry) in *host-inline-functions*
        do (setf (gethash name (session-inline-functions session)) entry))
  session)
