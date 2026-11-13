;;;; Assumptions: the facts that specialized code and caches rely on.
;;;;
;;;; An assumption is a fact named by (KIND NAME), where KIND and NAME are
;;;; compared by EQ. Each has a version cell: a fixnum that changes when
;;;; the fact does. Two kinds of guard use it:
;;;;
;;;; - a check: a cache entry or a piece of specialized code keeps the
;;;;   version it was made under and compares it before it is used. It
;;;;   needs no registration, and cannot miss a change, but costs a load
;;;;   and a comparison each time.
;;;; - a push: the dependent registers a function on the assumption; when
;;;;   the fact changes the function runs and the registration is dropped.
;;;;   Nothing to check, but a change that does not go through
;;;;   CHANGE-ASSUMPTION goes unnoticed, and the dependent must register
;;;;   again when it is remade (a cache that is filled again, code that is
;;;;   specialized again).
;;;;
;;;; Dependent kinds: a cache to empty, specialized code to put back to its
;;;; general version, and a definition to compile again (through the
;;;; redefinition hook, like the dependency keys). A watcher registered for
;;;; a whole kind is for caches of global facts, which cannot enumerate
;;;; what they depend on: the discriminating functions' call caches, the
;;;; TYPEP tables.
;;;;
;;;; Kinds:
;;;;   :class NAME           one cell per class: its layout, precedence list
;;;;                         and finalization
;;;;   :methods NAME         one cell per generic function: its methods and
;;;;                         its method combination
;;;;   :function NAME        one cell per function
;;;;   :macro, :setf, :inline, :constant NAME
;;;;                         one cell per definition (the dependency keys)
;;;;   :type NAME            one shared cell: DEFTYPE expansions and the
;;;;                         mapping of names to classes
;;;;   :initialization NAME  one shared cell: the methods that initialize
;;;;                         instances of classes
;;;; The two shared cells are coarse for now: emptying every typep cache
;;;; when a type changes is what the caches did before they were unified,
;;;; and the initialization methods apply to many classes at once.

(in-package #:kiln.kernel)

;;; The symbol plist helpers and PROCLAIM come first: the first DEFVAR
;;; below proclaims its variable special at load time, and that calls
;;; PROCLAIM. %PUT and %GET use only primitives, for the definitions that
;;; run before GET exists.
(defun %put (symbol indicator value)
  (do ((l (%primop :symbol-plist symbol) (cdr (cdr l))))
      ((null l)
       (%primop :set-symbol-plist symbol
                (cons indicator (cons value (%primop :symbol-plist symbol))))
       value)
    (when (eq (car l) indicator)
      (rplaca (cdr l) value)
      (return value))))

(defun %get (symbol indicator)
  (do ((l (%primop :symbol-plist symbol) (cdr (cdr l))))
      ((null l) nil)
    (when (eq (car l) indicator)
      (return (car (cdr l))))))

(defun %has-property (symbol indicator)
  (do ((l (%primop :symbol-plist symbol) (cdr (cdr l))))
      ((null l) nil)
    (when (eq (car l) indicator)
      (return t))))

(defun type-name-p (name)
  (and (symbolp name)
       (or (member name '(nil t null atom cons list symbol keyword character function
                         compiled-function string base-string simple-string simple-base-string
                         vector simple-vector bit-vector simple-bit-vector array simple-array
                         sequence number real rational integer fixnum bignum ratio float
                         single-float double-float short-float long-float bit boolean
                         standard-char base-char extended-char signed-byte unsigned-byte mod))
           (get name 'type-expander)
           (and (fboundp 'find-class) (find-class name nil)))))

(defun type-specifier-p (specifier)
  (cond ((symbolp specifier) (type-name-p specifier))
        ((consp specifier)
         (or (member (car specifier) '(and or not eql member satisfies))
             (type-name-p (car specifier))))
        (t (and (fboundp 'find-class) (find-class 'class nil)
                (typep specifier 'class)))))

(defun check-type-name (name)
  (when (get name '%declaration)
    (error "~S is a declaration name and cannot name a type." name))
  name)

(defun proper-declaration-p (declaration)
  (and (consp declaration) (symbolp (car declaration))
       (do ((slow declaration) (fast declaration))
           (nil)
         (cond ((null fast) (return t))
               ((not (consp fast)) (return nil))
               ((null (cdr fast)) (return t))
               ((not (consp (cdr fast))) (return nil)))
         (setq slow (cdr slow) fast (cddr fast))
         (when (eq slow fast) (return nil)))))

(defun function-inline-declaration (name)
  (if (consp name) (%get (cadr name) '%setf-inline-declaration)
      (%get name '%inline-declaration)))

;;; Runtime proclamations retain binding, declaration and optimization facts.
;;; The compiler hook maintains compilation-specific state.
(defun proclaim (declaration)
  (declare (special *proclaim-hook* *declaration-names* *optimization-qualities*))
  (unless (proper-declaration-p declaration)
    (error 'program-error))
  (when (and (consp declaration) (eq (car declaration) 'special))
    (dolist (name (cdr declaration))
      (when (%has-property name '%symbol-macro)
        (error 'program-error))
      (%put name '%special t)))
  (when (and (consp declaration) (eq (car declaration) 'declaration))
    (dolist (name (cdr declaration))
      (unless (symbolp name)
        (error 'type-error :datum name :expected-type 'symbol))
      (when (type-name-p name)
        (error "~S names a type and cannot name a declaration." name))
      (%put name '%declaration t)
      (unless (member name *declaration-names*)
        (push name *declaration-names*))))
  (when (eq (car declaration) 'optimize)
    (dolist (entry (cdr declaration))
      (let* ((name (if (consp entry) (car entry) entry))
             (level (if (consp entry)
                        (if (and (consp (cdr entry)) (null (cddr entry))) (cadr entry)
                            (error 'program-error))
                        3))
             (index (case name (speed 0) (safety 1) (debug 2) (space 3) (compilation-speed 4)
                           (otherwise (error 'program-error)))))
        (unless (and (integerp level) (<= 0 level 3)) (error 'program-error))
        (setf (svref *optimization-qualities* index) level))))
  (when (or (eq (car declaration) 'inline) (eq (car declaration) 'notinline))
    (dolist (name (cdr declaration))
      (if (consp name)
          (%put (cadr name) '%setf-inline-declaration (car declaration))
          (%put name '%inline-declaration (car declaration)))))
  (when (and (boundp '*proclaim-hook*) *proclaim-hook*)
    (funcall *proclaim-hook* declaration))
  nil)

;;; (The first DEFVAR: its DECLAIM calls PROCLAIM, which is defined above.)
(defvar *proclaim-hook* nil)
(defvar *declaration-names* nil)
(defvar *optimization-qualities* (vector 3 3 3 3 3))

;;; The redefinition hook: the compiler module's dependency tracking
;;; (lisp/target/compiler/dependencies.lisp), NIL before it is loaded.
(defvar *redefinition-hook* nil)

(defun note-redefinition (kind name)
  (let ((hook *redefinition-hook*))
    (when hook
      (funcall hook (cons kind (cons name nil))))))

;;; A version cell: version (a fixnum), then the transient registrations.
;;; Each registration holds its callback and cell until consumed or cancelled.
(defun make-assumption-cell ()
  (let ((cell (%primop :make-simple-vector 2 nil)))
    (setf (svref cell 0) 0)
    cell))

;;; Observed assumptions only: changes do not allocate a cell until a
;;; guard or dependent asks for one. The keys and cells are parallel.
(defvar *assumption-keys* (%primop :make-simple-vector 256 nil))
(defvar *assumption-cells* (%primop :make-simple-vector 256 nil))
(defvar *assumption-table-size* 256)
(defvar *assumption-count* 0)

;;; The shared cells of the type and class initialization assumptions.
(defvar *type-assumption-cell* (make-assumption-cell))
(defvar *initialization-assumption-cell* (make-assumption-cell))

;;; Open addressing with linear probing: the kinds and names are compared
;;; by EQ, and the table is small enough that a simple mix of the two
;;; identity hashes spreads well. (Hash tables do not exist yet when the
;;; kernel loads.)
(defun assumption-index (kind name mask)
  (%primop :fixnum-logand
           (%primop :hash-mix (%primop :identity-hash kind)
                    (%primop :identity-hash name))
           mask))

(defun find-assumption-cell (kind name)
  "The cell of the assumption (KIND NAME), or NIL if there is none."
  (let* ((keys *assumption-keys*)
         (mask (- *assumption-table-size* 1))
         (index (assumption-index kind name mask)))
    (do () (nil)
      (let ((key (svref keys index)))
        (cond ((null key) (return nil))
              ((and (eq (car key) kind) (eq (cdr key) name))
               (return (svref *assumption-cells* index)))
              (t (setq index (%primop :fixnum-logand (+ index 1) mask))))))))

(defun rehash-assumptions (size &optional excluded-cell)
  (let* ((old-size *assumption-table-size*)
         (mask (- size 1))
         (old-keys *assumption-keys*)
         (old-cells *assumption-cells*)
         (keys (%primop :make-simple-vector size nil))
         (cells (%primop :make-simple-vector size nil)))
    (dotimes (i old-size)
      (let ((key (svref old-keys i)))
        (when (and key (not (eq (svref old-cells i) excluded-cell)))
          (let ((index (assumption-index (car key) (cdr key) mask)))
            (do () (nil)
              (when (null (svref keys index))
                (setf (svref keys index) key)
                (setf (svref cells index) (svref old-cells i))
                (return nil))
              (setq index (%primop :fixnum-logand (+ index 1) mask)))))))
    (setf *assumption-keys* keys
          *assumption-cells* cells
          *assumption-table-size* size)))

(defun register-assumption-cell (kind name cell)
  (when (>= (* 4 (+ *assumption-count* 1)) (* 3 *assumption-table-size*))
    (rehash-assumptions (* 2 *assumption-table-size*)))
  (let* ((mask (- *assumption-table-size* 1))
         (index (assumption-index kind name mask)))
    (do () (nil)
      (when (null (svref *assumption-keys* index))
        (setf (svref *assumption-keys* index) (cons kind name))
        (setf (svref *assumption-cells* index) cell)
        (setf *assumption-count* (+ *assumption-count* 1))
        (return nil))
      (setq index (%primop :fixnum-logand (+ index 1) mask)))))

(defun assumption-name (kind name)
  "Canonicalizes SETF function names so independently made lists share a cell."
  (if (and (or (eq kind :function) (eq kind :inline) (eq kind :compiler-macro))
           (consp name) (eq (car name) 'setf)
           (consp (cdr name)) (symbolp (cadr name)) (null (cddr name)))
      (or (%get (cadr name) '%setf-assumption-name)
          (%put (cadr name) '%setf-assumption-name name))
      name))

(defun assumption-cell (kind name)
  "The version cell of the assumption (KIND NAME), made if it is new."
  (setq name (assumption-name kind name))
  (cond ((eq kind :type) *type-assumption-cell*)
        ((eq kind :initialization) *initialization-assumption-cell*)
        (t (or (find-assumption-cell kind name)
               (let ((cell (make-assumption-cell)))
                 (register-assumption-cell kind name cell)
                 cell)))))

;;; Guards on hot paths read the cells directly; these are for the places
;;; that are not hot.
(defun type-assumption-version ()
  (svref *type-assumption-cell* 0))

(defun kiln.sys:assumption-version (kind name)
  "The version of the assumption (KIND NAME): a fixnum that changes when
the fact it stands for changes. Making a new assumption gives it version 0."
  (svref (assumption-cell kind name) 0))

(defun kiln.sys:assumptions ()
  "The assumptions with version cells, as (KIND NAME VERSION) lists."
  (let ((result '()))
    (dotimes (i *assumption-table-size*)
      (let ((key (svref *assumption-keys* i)))
        (when key
          (push (list (car key) (cdr key)
                      (svref (svref *assumption-cells* i) 0))
                result))))
    (push (list :type '* (svref *type-assumption-cell* 0)) result)
    (push (list :initialization '* (svref *initialization-assumption-cell* 0))
          result)
    result))

;;; Push-style dependents

(defun register-assumption-dependent (kind name function)
  "Calls FUNCTION when (KIND NAME) changes. Returns a cancellable registration.
A registration is consumed before its callback runs."
  (let* ((cell (assumption-cell kind name))
         (registration (cons function cell)))
    (setf (svref cell 1) (cons registration (svref cell 1)))
    registration))

(defun cancel-assumption-dependent (registration)
  "Cancels REGISTRATION and releases its callback and cell. Safe to repeat."
  (let ((cell (cdr registration)))
    (when cell
      (setf (svref cell 1) (delete registration (svref cell 1) :test #'eq))))
  (setf (car registration) nil (cdr registration) nil)
  nil)

;;; For each kind, the functions called with the changed names: a cache of
;;; a global fact that loses its validity when any assumption of the kind
;;; changes. One entry per kind, (KIND . FUNCTIONS).
(defvar *assumption-watchers* '())

(defun register-assumption-watcher (kind function)
  "Call FUNCTION with the list of names whose assumption of KIND changed.
Returns FUNCTION."
  (let ((entry nil))
    (dolist (e *assumption-watchers*)
      (when (null entry)
        (when (eq (car e) kind) (setq entry e))))
    (let ((present nil))
      (dolist (f (cdr entry))
        (when (eq f function) (setq present t)))
      (unless present
        (if entry
            (setf (cdr entry) (cons function (cdr entry)))
            (setf *assumption-watchers*
                  (cons (cons kind (cons function nil)) *assumption-watchers*)))))
    function))

(defun unregister-assumption-watcher (kind function)
  "Removes FUNCTION from the watchers of KIND. Safe to repeat."
  (dolist (entry *assumption-watchers*)
    (when (eq (car entry) kind)
      (setf (cdr entry) (delete function (cdr entry) :test #'eq))))
  (setf *assumption-watchers*
        (delete-if (lambda (entry) (null (cdr entry))) *assumption-watchers*))
  nil)

(defun run-assumption-notifications (notifications)
  ;; An observer must not prevent the remaining caches from being invalidated.
  (unwind-protect
       (loop while notifications
             do (let ((notification (pop notifications)))
                  (apply (car notification) (cdr notification))))
    (when notifications (run-assumption-notifications notifications))))

(defun note-assumption-change (keys)
  "Runs watchers, then the redefinition hook, for each distinct change."
  (let ((notifications '()))
    (dolist (entry *assumption-watchers*)
      (let ((names '()))
        (dolist (key keys)
          (when (eq (car entry) (car key)) (push (cdr key) names)))
        (when names
          (dolist (watcher (cdr entry))
            (push (list watcher names) notifications)))))
    (dolist (key keys)
      (push (list #'note-redefinition (car key) (cdr key)) notifications))
    (run-assumption-notifications (reverse notifications))))

(defvar *deferring-assumptions* nil)
(defvar *deferred-assumption-keys* '())

(defun run-assumption-dependents (registrations)
  ;; Cleanup drains callbacks after an error as well: every dependent must
  ;; lose its specialization, even when another dependent exits nonlocally.
  (unwind-protect
       (loop while registrations
             do (let* ((registration (pop registrations))
                       (function (car registration)))
                  (setf (car registration) nil (cdr registration) nil)
                  (when function (funcall function))))
    (when registrations (run-assumption-dependents registrations))))

(defun invalidate-assumption-cell (kind name cell)
  (if (not (or cell *redefinition-hook*
               (loop for entry in *assumption-watchers*
                     thereis (eq (car entry) kind))))
      0
      (defer-assumption-changes
       (lambda ()
         (let ((version (if cell (+ (svref cell 0) 1) 0)))
           (when cell (setf (svref cell 0) version))
           ;; Queue before callbacks: their exits must still notify caches.
           (unless (loop for key in *deferred-assumption-keys*
                         thereis (and (eq (car key) kind) (eq (cdr key) name)))
             (push (cons kind name) *deferred-assumption-keys*))
           (when cell
             (let ((registrations (svref cell 1)))
               (setf (svref cell 1) nil)
               (run-assumption-dependents registrations)))
           version)))))

(defun change-assumption (kind name)
  "Changes (KIND NAME), invalidates its guards and notifies dependents.
Unobserved facts need no cell; returns zero for those, or the new version."
  (setq name (assumption-name kind name))
  (invalidate-assumption-cell
   kind name
   (cond ((eq kind :type) *type-assumption-cell*)
         ((eq kind :initialization) *initialization-assumption-cell*)
         (t (find-assumption-cell kind name)))))

(defun defer-assumption-changes (thunk)
  "Calls THUNK; the watchers and the redefinition hook see the assumptions
it changes together when it exits, including nonlocal exits.
Nested calls join the outer one."
  (if *deferring-assumptions*
      (funcall thunk)
      (let ((*deferring-assumptions* t)
            (*deferred-assumption-keys* '()))
        (unwind-protect (funcall thunk)
          (let ((keys *deferred-assumption-keys*))
            (setq *deferred-assumption-keys* '())
            (when keys
              (let ((*deferring-assumptions* nil))
                (note-assumption-change keys))))))))

(defun release-assumption (kind name)
  "Retires an observed assumption, releasing its key and invalidating old guards.
Use when its owner is discarded. Existing cells stay invalid; a later lookup
creates a new cell. Shared type and initialization cells cannot be retired."
  (setq name (assumption-name kind name))
  (when (or (eq kind :type) (eq kind :initialization))
    (error "Cannot release a shared assumption: ~S" kind))
  (let ((cell (find-assumption-cell kind name)))
    (when cell
      ;; Detach first: callbacks can safely register a new lifetime of this key.
      (rehash-assumptions *assumption-table-size* cell)
      (decf *assumption-count*)
      (invalidate-assumption-cell kind name cell)))
  nil)

(defvar *trace-definition-hook* nil)

(defun note-function-change (name)
  "A function binding changed, including removal of the binding."
  (when (and (symbolp name) (%get name '%macro-function))
    (%put name '%macro-function nil)
    (change-assumption :macro name))
  (when *trace-definition-hook*
    (funcall *trace-definition-hook* name))
  (change-assumption :function name))
