;;;; Dependency tracking (docs/18): a definition evaluated in the image
;;;; (by EVAL, so LOAD and the back-end protocol) records the definitions
;;;; its code depends on at compile time, the keys that front.lisp and
;;;; client.lisp note in *DEPENDENCIES*. When one of those is defined
;;;; again (kiln.kernel::*REDEFINITION-HOOK*), the definitions that depend
;;;; on it are evaluated again, so that their code sees the new
;;;; definition; those that cannot be (a DEFVAR, a DEFCLASS: evaluating
;;;; them again has other effects) are reported.

(in-package #:kiln.compiler)

(defstruct (definition-unit (:constructor make-definition-unit (name form package keys)))
  name                                  ; DEFINITION-NAME of FORM
  form                                  ; the definition, as EVAL got it
  package                               ; *PACKAGE* when it was evaluated
  keys)                                 ; its dependencies, (KIND NAME)

(defvar *definition-units* (make-hash-table :test 'equal)
  "The definitions with dependencies, by name.")

(defvar *dependents* (make-hash-table :test 'equal)
  "For a key (KIND NAME), the definition units that depend on it.")

(defvar *pending-redefinitions* '()
  "The keys of the definitions that changed: their dependents are
updated once the outermost EVAL in progress returns.")

(defvar *evaluating* nil
  "True during EVAL (NATIVE-EVAL).")

(defvar kiln.sys:*recompile-verbose* nil
  "True: a definition evaluated again because one it depends on changed
is reported on *ERROR-OUTPUT*.")

(defparameter *reevaluated-operators*
  '(defun defmacro defmethod define-compiler-macro deftype defsetf
    define-setf-expander define-modify-macro)
  "Definitions that are evaluated again when one they depend on changes:
evaluating them again only replaces what they define.")

(define-condition kiln.sys:stale-definition (style-warning)
  ((name :initarg :name :reader stale-definition-name)
   (key :initarg :key :reader stale-definition-key)
   (error :initarg :error :initform nil :reader stale-definition-error))
  (:report (lambda (c s)
             (if (stale-definition-error c)
                 (format s "~S could not be compiled again after ~A changed: ~A"
                         (stale-definition-name c)
                         (describe-dependency (stale-definition-key c))
                         (stale-definition-error c))
                 (format s "~S depends on ~A, which changed: evaluate it again"
                         (stale-definition-name c)
                         (describe-dependency (stale-definition-key c)))))))

(defun describe-dependency (key)
  (destructuring-bind (kind name) key
    (format nil (ecase kind
                  (:macro "the macro ~S")
                  (:inline "the inline function ~S")
                  (:setf "the SETF expander of ~S")
                  (:constant "the constant ~S"))
            name)))

(defun remove-definition-unit (name)
  (let ((old (gethash name *definition-units*)))
    (when old
      (remhash name *definition-units*)
      (dolist (key (definition-unit-keys old))
        (let ((units (delete old (gethash key *dependents*))))
          (if units
              (setf (gethash key *dependents*) units)
              (remhash key *dependents*)))))))

(defun register-definition-unit (name form keys)
  "The definition FORM, named NAME, has been evaluated: its dependencies
are KEYS (replacing those of its previous evaluation)."
  (remove-definition-unit name)
  (when keys
    (let ((unit (make-definition-unit name form *package* keys)))
      (setf (gethash name *definition-units*) unit)
      (dolist (key keys)
        (push unit (gethash key *dependents*))))))

(defun evaluate-definition (name form evaluate)
  "Calls EVALUATE, which evaluates the definition FORM named NAME,
collecting the dependencies of the code compiled for it; returns its
values. A definition within FORM's expansion is a unit of its own."
  (let ((*dependencies* (list :dependencies)))
    (note-dependency :macro (first form))
    (multiple-value-prog1 (funcall evaluate)
      (register-definition-unit name form (reverse (rest *dependencies*))))))

;;; Redefinitions

(defun note-redefinition (key)
  "*REDEFINITION-HOOK*: the definition KEY changed."
  (when (gethash key *dependents*)
    (unless (member key *pending-redefinitions* :test #'equal)
      (setf *pending-redefinitions* (append *pending-redefinitions* (list key))))
    ;; Not in the middle of EVAL or of a compilation: now.
    (unless (or *evaluating* (boundp '*client*))
      (update-dependents))))

(defun update-dependents ()
  "Evaluates again the definitions that depend on the pending keys, in
the order they were defined, and so on for the definitions those define.
A definition is evaluated at most once for each key."
  (let ((*evaluating* t)
        (done '()))
    (loop while *pending-redefinitions*
          do (let ((key (pop *pending-redefinitions*)))
               (dolist (unit (reverse (gethash key *dependents*)))
                 (let ((name (definition-unit-name unit)))
                   (when (and (eq (gethash name *definition-units*) unit)
                              (not (member (cons name key) done :test #'equal)))
                     (push (cons name key) done)
                     (update-definition unit key))))))))

(defun update-definition (unit key)
  (let ((name (definition-unit-name unit))
        (form (definition-unit-form unit)))
    (cond ((member (first form) *reevaluated-operators*)
           (when kiln.sys:*recompile-verbose*
             (format *error-output* "~&; compiling ~S again: ~A changed~%"
                     name (describe-dependency key)))
           (handler-case
               (let ((*package* (definition-unit-package unit)))
                 (eval form))
             (error (e)
               (warn 'kiln.sys:stale-definition :name name :key key :error e))))
          (t
           (warn 'kiln.sys:stale-definition :name name :key key)))))

(defun kiln.sys:dependents (kind name)
  "The names of the definitions evaluated in the image whose code depends
on the definition (KIND NAME): KIND is :MACRO, :INLINE, :SETF or
:CONSTANT."
  (mapcar #'definition-unit-name (reverse (gethash (list kind name) *dependents*))))

(defun kiln.sys:dependencies (name)
  "The dependencies (KIND NAME) of the definition named NAME (as in a
backtrace: F, (MACRO-FUNCTION M), (METHOD F ...)), evaluated in the
image."
  (let ((unit (gethash name *definition-units*)))
    (and unit (definition-unit-keys unit))))

(setf kiln.kernel::*redefinition-hook* 'note-redefinition)
