;;;; Dependency tracking: a definition evaluated in the image
;;;; (by EVAL, so LOAD and the back-end protocol) records the definitions
;;;; its code depends on at compile time, the keys that front.lisp and
;;;; client.lisp note in *DEPENDENCIES*. When one of those is defined
;;;; again (kiln.kernel::*REDEFINITION-HOOK*), the definitions that depend
;;;; on it are evaluated again, so that their code sees the new
;;;; definition; those that cannot be (a DEFVAR, a DEFCLASS: evaluating
;;;; them again has other effects) are reported.
;;;;
;;;; An update is ordered and cut off as in Zig's incremental
;;;; compilation: the definitions that depend on a changed one are
;;;; outdated, those that depend on what these define are potentially
;;;; outdated, with a count of the definitions they wait for; a definition
;;;; is evaluated again once that count is 0, and if what it defines comes
;;;; out the same (the same code), the definitions waiting for it need not
;;;; be.

(in-package #:kiln.compiler)

(defstruct (definition-unit (:constructor make-definition-unit
                                (name form package keys outputs fingerprint order file source-cst)))
  name                                  ; DEFINITION-NAME of FORM
  form                                  ; the definition, as EVAL got it
  package                               ; *PACKAGE* when it was evaluated
  keys                                  ; its dependencies, (KIND NAME)
  outputs                               ; the keys its evaluation changed
  fingerprint                           ; the code compiled for it
  order                                 ; when it was first defined
  file source-cst)                       ; source retained for recompilation

(defvar *definition-units* (make-hash-table :test 'equal)
  "The definitions with dependencies, by name.")

(defvar *dependents* (make-hash-table :test 'equal)
  "For a key (KIND NAME), the definition units that depend on it.")

(defvar *definition-order* 0)

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

(defun dependency-name (object)
  "OBJECT for a report: the name of a class or a generic function, or the
object itself."
  (cond ((typep object 'clostrophilia:class)
         (or (clostrophilia:class-name object) object))
        ((typep object 'clostrophilia:generic-function)
         (or (clostrophilia:generic-function-name object) object))
        (t object)))

(defun describe-dependency (key)
  (destructuring-bind (kind name) key
    (case kind
      (:macro (format nil "the macro ~S" name))
      (:compiler-macro (format nil "the compiler macro ~S" name))
      (:inline (format nil "the inline function ~S" name))
      (:setf (format nil "the SETF expander of ~S" name))
      (:constant (format nil "the constant ~S" name))
      (:function (format nil "the function ~S" name))
      (:type (format nil "the type ~S" (dependency-name name)))
      (:class (format nil "the class ~S" (dependency-name name)))
      (:methods (format nil "the methods of ~S" (dependency-name name)))
      (:initialization "the class initialization methods")
      (t (format nil "~S ~S" kind name)))))

;;; Recording

(defvar *unit-outputs* nil
  "While a definition is evaluated: a cons whose cdr collects the keys of
the definitions its evaluation changes.")

(defvar *unit-fingerprint* nil
  "While a definition is evaluated: a cons whose cdr collects the code
compiled for it (NOTE-COMPILED-CODE).")

(defvar *captured-fingerprint* nil
  "UPDATE-DEFINITION: (NAME . FINGERPRINT) once the definition NAME has
been evaluated again.")

(defun replace-all (string old new)
  (with-output-to-string (out)
    (loop with start = 0
          for position = (search old string :start2 start)
          do (write-string string out :start start :end (or position (length string)))
          while position
          do (write-string new out)
             (setf start (+ position (length old))))))

(defun note-compiled-code (module-name packet literals)
  "Records canonical backend bytes and literal identities for this definition."
  (declare (ignore module-name))
  (when *unit-fingerprint*
    (push (cons packet literals) (cdr *unit-fingerprint*))))

(defun similar-literal-p (a b depth)
  "Are the literals A and B the same as far as code goes: EQL, or equal
strings, conses, vectors, uninterned symbols with the same name (the
gensyms of a macro expansion)?"
  (cond ((eql a b) t)
        ((zerop depth) nil)
        ((and (consp a) (consp b))
         (and (similar-literal-p (car a) (car b) (1- depth))
              (similar-literal-p (cdr a) (cdr b) (1- depth))))
        ((and (stringp a) (stringp b)) (string= a b))
        ((and (simple-vector-p a) (simple-vector-p b))
         (and (= (length a) (length b))
              (every (lambda (x y) (similar-literal-p x y (1- depth))) a b)))
        ((and (symbolp a) (symbolp b))
         (and (null (symbol-package a)) (null (symbol-package b))
              (string= (symbol-name a) (symbol-name b))))
        ((and (numberp a) (numberp b)) (eql a b))
        (t nil)))

(defun same-fingerprint-p (a b)
  (and (= (length a) (length b))
       (every (lambda (x y)
                (and (equalp (car x) (car y))
                     (= (length (cdr x)) (length (cdr y)))
                     (every (lambda (p q) (similar-literal-p p q 100)) (cdr x) (cdr y))))
              a b)))

(defun remove-definition-unit (name)
  (let ((old (gethash name *definition-units*)))
    (when old
      (remhash name *definition-units*)
      (dolist (key (definition-unit-keys old))
        (let ((units (delete old (gethash key *dependents*))))
          (if units
              (setf (gethash key *dependents*) units)
              (remhash key *dependents*)))))
    old))

(defun register-definition-unit (name form keys outputs fingerprint)
  "The definition FORM, named NAME, has been evaluated: its dependencies
are KEYS (replacing those of its previous evaluation)."
  (let ((old (remove-definition-unit name)))
    (when keys
      (let ((unit (make-definition-unit name form *package* keys outputs fingerprint
                                        (if old
                                            (definition-unit-order old)
                                            (incf *definition-order*))
                                        *source-file* *eval-source-cst*)))
        (setf (gethash name *definition-units*) unit)
        (dolist (key keys)
          (setf (gethash key *dependents*)
                (merge 'list (list unit) (gethash key *dependents*) #'<
                       :key #'definition-unit-order)))))))

(defun evaluate-definition (name form evaluate)
  "Calls EVALUATE, which evaluates the definition FORM named NAME,
collecting the dependencies of the code compiled for it; returns its
values. A definition within FORM's expansion is a unit of its own."
  (let ((*dependencies* (list :dependencies))
        (*unit-outputs* (list :outputs))
        (*unit-fingerprint* (list :fingerprint)))
    (note-dependency :macro (first form))
    (multiple-value-prog1 (funcall evaluate)
      (let ((fingerprint (reverse (rest *unit-fingerprint*))))
        (when (and *captured-fingerprint* (equal name (car *captured-fingerprint*)))
          (setf (cdr *captured-fingerprint*) fingerprint))
        (register-definition-unit name form (reverse (rest *dependencies*))
                                  (reverse (rest *unit-outputs*)) fingerprint)))))

;;; Redefinitions

(defvar *update-notes* nil
  "While UPDATE-DEFINITION evaluates a definition again: a cons whose cdr
collects the keys that change.")

(defun note-redefinition (key)
  "*REDEFINITION-HOOK*: the definition KEY changed."
  (let ((outputs *unit-outputs*))
    (when (and outputs (not (member key (cdr outputs) :test #'equal)))
      (push key (cdr outputs))))
  (cond (*update-notes*
         (pushnew key (cdr *update-notes*) :test #'equal))
        ((gethash key *dependents*)
         (unless (member key *pending-redefinitions* :test #'equal)
           (setf *pending-redefinitions* (append *pending-redefinitions* (list key))))
         ;; Not in the middle of EVAL or of a compilation: now.
         (unless (or *evaluating* (boundp '*client*))
           (update-dependents)))))

;;; An update. The tables are by definition name: OUTDATED and POTENTIALLY
;;; OUTDATED map a name to the number of definitions it waits for, DONE
;;; holds those evaluated again in this update (at most once each).

(defvar *outdated*)
(defvar *potentially-outdated*)
(defvar *done*)
(defvar *changed-keys* '())             ; the keys that changed in this update

(defun dependent-names (key)
  (mapcar #'definition-unit-name (gethash key *dependents*)))

(defun unit-outputs (name)
  (let ((unit (gethash name *definition-units*)))
    (and unit (definition-unit-outputs unit))))

(defun mark-potentially-outdated (name)
  "NAME has just become outdated or potentially outdated: so are the
definitions that depend on what it defines, each waiting for one more."
  (dolist (key (unit-outputs name))
    (dolist (dependent (dependent-names key))
      (cond ((gethash dependent *done*))
            ((nth-value 1 (gethash dependent *outdated*))
             (incf (gethash dependent *outdated*)))
            ((nth-value 1 (gethash dependent *potentially-outdated*))
             (incf (gethash dependent *potentially-outdated*)))
            (t
             (setf (gethash dependent *potentially-outdated*) 1)
             (mark-potentially-outdated dependent))))))

(defun mark-changed (key counted)
  "KEY changed: the definitions that depend on it are outdated. COUNTED:
they were waiting for the definition that changed it."
  (push key *changed-keys*)
  (dolist (dependent (dependent-names key))
    (unless (gethash dependent *done*)
      (multiple-value-bind (count outdatedp) (gethash dependent *outdated*)
        (multiple-value-bind (po-count po-p) (gethash dependent *potentially-outdated*)
          (cond (outdatedp
                 (when counted (setf (gethash dependent *outdated*) (1- count))))
                (po-p
                 (remhash dependent *potentially-outdated*)
                 (setf (gethash dependent *outdated*) (if counted (1- po-count) po-count)))
                (t
                 (setf (gethash dependent *outdated*) 0)
                 (mark-potentially-outdated dependent))))))))

(defun mark-unchanged (key)
  "KEY's definition was evaluated again and came out the same: the
definitions that depend on it wait for one less; a potentially outdated
one that waits for none is up to date, and so is what it defines."
  (dolist (dependent (dependent-names key))
    (unless (gethash dependent *done*)
      (multiple-value-bind (count outdatedp) (gethash dependent *outdated*)
        (multiple-value-bind (po-count po-p) (gethash dependent *potentially-outdated*)
          (cond (outdatedp
                 (setf (gethash dependent *outdated*) (1- count)))
                (po-p
                 (if (> po-count 1)
                     (setf (gethash dependent *potentially-outdated*) (1- po-count))
                     (progn
                       (remhash dependent *potentially-outdated*)
                       (dolist (output (unit-outputs dependent))
                         (mark-unchanged output)))))))))))

(defun next-outdated ()
  "The outdated definition to evaluate next: the first defined of those
that wait for none; if all wait (a cycle), the first defined."
  (let ((ready nil) (any nil))
    (flet ((order (name)
             (let ((unit (gethash name *definition-units*)))
               (if unit (definition-unit-order unit) most-positive-fixnum))))
      (maphash (lambda (name count)
                 (when (or (null any) (< (order name) (order any)))
                   (setf any name))
                 (when (and (<= count 0) (or (null ready) (< (order name) (order ready))))
                   (setf ready name)))
               *outdated*))
    (or ready any)))

(defvar *updating-definitions* nil)

(defun update-outdated-definition (name)
  ;; Mark before evaluation so a back edge observes the active definition
  ;; instead of recursively trying to compile it again.
  (remhash name *outdated*)
  (remhash name *potentially-outdated*)
  (setf (gethash name *done*) t)
  (let ((unit (gethash name *definition-units*)))
    (when unit
      (let ((*updating-definitions* (cons name *updating-definitions*)))
        (update-definition unit)))))

(defun dependency-reaches-active-p (name &optional seen)
  (or (member name *updating-definitions* :test #'equal)
      (unless (member name seen :test #'equal)
        (let ((unit (gethash name *definition-units*)))
          (some (lambda (key)
                  (and (eq (first key) :macro)
                       (dependency-reaches-active-p (list 'macro-function (second key))
                                                    (cons name seen))))
                (and unit (definition-unit-keys unit)))))))

(defun prepare-definition-dependency (key)
  "Refresh a pending macro before its expander is used in a cycle."
  (when (and (boundp '*outdated*) (eq (first key) :macro))
    (let ((name (list 'macro-function (second key))))
      (when (and (not (gethash name *done*))
                 (not (dependency-reaches-active-p name))
                 (or (nth-value 1 (gethash name *outdated*))
                     (nth-value 1 (gethash name *potentially-outdated*))))
        (update-outdated-definition name)))))

(setf *dependency-query-hook* #'prepare-definition-dependency)

(defun update-dependents ()
  "Evaluates again the definitions that depend on the pending keys, and
so on for the definitions those change."
  (let ((*evaluating* t)
        (*outdated* (make-hash-table :test 'equal))
        (*potentially-outdated* (make-hash-table :test 'equal))
        (*done* (make-hash-table :test 'equal))
        (*changed-keys* '()))
    (loop while *pending-redefinitions*
          do (mark-changed (pop *pending-redefinitions*) nil)
             (loop for name = (next-outdated)
                   while name
                   do (update-outdated-definition name)))))

(defun update-definition (unit)
  "Evaluates UNIT again if it is one of the definitions that can be, or
reports it; then tells the definitions that depend on what it defines
whether that changed."
  (let* ((name (definition-unit-name unit))
         (form (definition-unit-form unit))
         (previous (definition-unit-outputs unit))
         (changed '()))
    (cond ((member (first form) *reevaluated-operators*)
           (when kiln.sys:*recompile-verbose*
             (format *error-output* "~&; compiling ~S again: ~A changed~%"
                     name (describe-dependency (stale-key unit))))
           (let ((*update-notes* (list :notes))
                 (*captured-fingerprint* (list name)))
             (handler-case
                 (let ((*package* (definition-unit-package unit))
                       (*source-file* (definition-unit-file unit))
                       (*eval-source-cst* (definition-unit-source-cst unit)))
                   (eval form)
                   ;; A macro or SETF expander whose code is the same is
                   ;; the same; constants and inline expansions are noted
                   ;; only when they change.
                   (let ((same-code (same-fingerprint-p (cdr *captured-fingerprint*)
                                                        (definition-unit-fingerprint unit))))
                     (setf changed
                           (remove-if (lambda (key)
                                        (and same-code (member (first key) '(:macro :setf))))
                                      (cdr *update-notes*)))
                     (when (and same-code kiln.sys:*recompile-verbose*)
                       (format *error-output* "~&; ~S is the same~%" name))))
               (error (e)
                 (warn 'kiln.sys:stale-definition :name name
                       :key (stale-key unit) :error e)))))
          (t
           (warn 'kiln.sys:stale-definition :name name :key (stale-key unit))))
    (dolist (key previous)
      (if (member key changed :test #'equal)
          (mark-changed key t)
          (mark-unchanged key)))
    (dolist (key changed)
      (unless (member key previous :test #'equal)
        (mark-changed key nil)))))

(defun stale-key (unit)
  "A dependency of UNIT that changed, for a report."
  (or (find-if (lambda (key) (member key *changed-keys* :test #'equal))
               (definition-unit-keys unit))
      (first (definition-unit-keys unit))))

(defun kiln.sys:dependents (kind name)
  "The names of the definitions evaluated in the image whose code depends
on the definition or assumption (KIND NAME): KIND is :MACRO, :INLINE,
:SETF, :CONSTANT, :FUNCTION, :TYPE, :CLASS, :METHODS or :INITIALIZATION."
  (dependent-names (list kind name)))

(defun kiln.sys:dependencies (name)
  "The dependencies (KIND NAME) of the definition named NAME (as in a
backtrace: F, (MACRO-FUNCTION M), (METHOD F ...)), evaluated in the
image."
  (let ((unit (gethash name *definition-units*)))
    (and unit (definition-unit-keys unit))))

(setf kiln.kernel::*redefinition-hook* 'note-redefinition)
