;;;; Compiling in the running image: IMAGE-CLIENT. Loaded
;;;; after front.lisp and cross.lisp. The compile-time environment is the run-time one,
;;;; as in other implementations: macros, special variables and constants
;;;; are the global environment's, and the code evaluated at compile time
;;;; (EVAL-WHEN, DEFMACRO, the proclamations of DEFVAR) runs in Maclina's VM
;;;; (the eval module), so its definitions take effect in the running image.
;;;; What the host's front end knew when it compiled the modules loaded
;;;; before the compiler (inline functions) comes from session.lisp.

(in-package #:kiln.compiler)

(defclass image-client (client) ())

(defmethod run-time-packages-p ((client image-client))
  t)

(defmethod compiles-into-image-p ((client image-client))
  t)

;;; Places: a symbol macro of the lexical environment, else as at run time
;;; (lisp/target/eval/macros.lisp).
(defmethod kiln.cmd:get-setf-expansion ((client image-client) place &optional environment)
  (let ((environment (or environment *environment*)))
    (multiple-value-bind (expansion macrop) (symbol-macro-expansion client environment place)
      (cond (macrop
             (kiln.cmd:get-setf-expansion client expansion environment))
            (t
             ;; A SETF expander defined later changes the expansion.
             (when (and (consp place) (symbolp (first place)))
               (note-dependency :setf (first place)))
             (call-next-method client place environment))))))

;;; The global environment, for Trucler: described as Maclina's client
;;; describes it (lisp/target/eval/evaluator.lisp), whatever the client.
;;; MACRO-FUNCTION with the front end's environment queries it with a
;;; reference client (environment.lisp).

(defclass run-time-environment () ())

(defvar *run-time-environment* (make-instance 'run-time-environment))

(defmethod trucler:global-environment (client (environment run-time-environment))
  (declare (ignore client))
  environment)

;;; The global macros and constants the compiled code uses are its
;;; dependencies; so are names not defined yet, which a later
;;; DEFMACRO may define.
(defmethod trucler:describe-variable (client (environment run-time-environment) name)
  (declare (ignore client))
  (let ((description (trucler:describe-variable maclina.machine:*client* nil name)))
    (when (typep description 'trucler:constant-variable-description)
      (note-dependency :constant name))
    description))

(defmethod trucler:describe-function (client (environment run-time-environment) name)
  (declare (ignore client))
  (let ((description (trucler:describe-function maclina.machine:*client* nil name)))
    (when (or (null description) (typep description 'trucler:global-macro-description))
      (note-dependency :macro name))
    description))

(defmethod trucler:describe-block (client (environment run-time-environment) name)
  (declare (ignore client name))
  nil)

(defmethod trucler:describe-tag (client (environment run-time-environment) tag)
  (declare (ignore client tag))
  nil)

(defmethod trucler:describe-declarations (client (environment run-time-environment))
  (declare (ignore client))
  (make-instance 'trucler:declarations-description :declarations kiln.kernel::*declaration-names*))

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

(defmethod evaluate-at-compile-time ((client image-client) input environment)
  (maclina.compile:eval (if (typep input 'cst:cst) (cst:raw input) input)
                        (maclina-environment environment)))

(defmethod ir-local-macro-expander ((client image-client) name lambda-list body environment)
  (maclina.compile:eval (ecclesia:parse-macro name lambda-list body)
                        (maclina-environment (ir-evaluation-environment environment))))

;;; Inline proclamations at compile time (DECLAIM) reach the front end
;;; through the kernel's PROCLAIM.
(setf kiln.kernel::*proclaim-hook*
      (lambda (declaration)
        (when (and (boundp '*client*) (typep *client* 'image-client)
                   (consp declaration) (member (first declaration) '(inline notinline)))
          (note-inline-proclamation (first declaration) (rest declaration)))))

(defvar *host-inline-functions*)        ; session.lisp

(defvar *image-inline-functions* nil
  "The inline proclamations and expansions of the image: those the host
knew of the modules (*HOST-INLINE-FUNCTIONS*), then those of the code
compiled in the image. One table for all sessions, so that a function
declared inline by one EVAL is expanded in the code of the next.")

(defun image-inline-functions ()
  (or *image-inline-functions*
      (let ((table (make-hash-table :test 'equal)))
        (loop for (name . entry) in *host-inline-functions*
              do (setf (gethash name table) entry))
        (setf *image-inline-functions* table))))

(defmethod initialize-session ((client image-client) session)
  ;; The packages of the image exist at run time (a symbol table's use
  ;; lists name only those, lower.lisp).
  (setf (session-packages session) (list-all-packages))
  (setf (session-inline-functions session) (image-inline-functions))
  (setf (session-structures session) *structures*)
  session)

(setf (macro-function 'defstruct) #'expand-defstruct)
