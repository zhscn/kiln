;;; Assumptions (lisp/target/assumptions.lisp): the version cells of the
;;; class, method, type and initialization facts, the dependents registered
;;; on them, and the caches that follow them. Also the call-site TYPEP
;;; caches, which used to keep an obsolete instance's old class's answers,
;;; and TYPEP answers cached from a class name whose class changed.

(defun show (x) (write-line (prin1-to-string x)))

(defun version (kind name) (kiln.sys:assumption-version kind name))

(defun assumption-entry (kind name)
  (find-if (lambda (entry) (and (eq (first entry) kind) (eq (second entry) name)))
           (kiln.sys:assumptions)))

;;; A class's assumption changes when it is defined again, and so does the
;;; type assumption of its name.
(defclass va () ())
(defclass vb () ())
(defvar *va* (make-instance 'va))
(defvar *va-class* (find-class 'va))
(defvar *va-version* (version :class *va-class*))
(defvar *va-type-version* (version :type 'va))
(defclass va () ())
(show (list (< *va-version* (version :class *va-class*))
            (< *va-type-version* (version :type 'va))))

;;; MAKE-INSTANCES-OBSOLETE finalizes the class again.
(defvar *obsolete-version* (version :class (find-class 'va)))
(make-instances-obsolete 'va)
(show (< *obsolete-version* (version :class (find-class 'va))))

;;; A dependent runs when its assumption changes, then is dropped.
(defvar *fired* 0)
(defvar *watcher-fired* 0)
(kiln.kernel::register-assumption-dependent
 :class *va-class*
 (lambda () (setq *fired* (+ *fired* 1))))
(defclass va () ())
(show *fired*)
(defclass va () ())
(show *fired*)

;;; The watcher of a kind sees the names of all the changes of a batch.
(kiln.kernel::register-assumption-watcher
 :class
 (lambda (names) (setq *watcher-fired* (+ *watcher-fired* (length names)))))
(defclass va () ())
(show (plusp *watcher-fired*))

;;; The type assumption: a DEFTYPE changes it; the shared cell serves the
;;; caches, so a change of anything empties them all.
(defvar *type-changes* 0)
(kiln.kernel::register-assumption-dependent
 :type 'assumption-test-type
 (lambda () (setq *type-changes* (+ *type-changes* 1))))
(defvar *type-version* (version :type 'assumption-test-type))
(deftype assumption-test-type () '(or integer null))
(show (list (< *type-version* (version :type 'assumption-test-type))
            *type-changes*))
(defclass vb () ())
(show *type-changes*)

;;; The call-site TYPEP cache is guarded by the type version: (SETF
;;; FIND-CLASS) maps a name to another class, and the call site follows.
(defun aliasedp (x) (typep x 'assumption-test-alias))
(defvar *va2* (make-instance 'va))
(setf (find-class 'assumption-test-alias) (find-class 'va))
(show (aliasedp *va2*))
(setf (find-class 'assumption-test-alias) (find-class 'vb))
(show (aliasedp *va2*))

;;; The staleness that the call-site cache had: after S-C is defined again
;;; its obsolete instance keeps its old stamp, for which the call sites had
;;; the old class's answers.
(defclass s-a () ())
(defclass s-b () ())
(defclass s-c (s-a) ())
(defun is-s-a (x) (typep x 's-a))
(defun is-s-b (x) (typep x 's-b))
(defvar *sc* (make-instance 's-c))
(show (list (is-s-a *sc*) (is-s-b *sc*)))
(defclass s-c (s-b) ())
(show (list (is-s-a *sc*) (is-s-b *sc*)))

;;; The discriminating functions' call caches are emptied when a class
;;; changes.
(defclass d-a () ())
(defclass d-b (d-a) ())
(defclass d-c (d-a) ())
(defgeneric pick (x))
(defmethod pick ((x d-a)) 'd-a)
(defmethod pick ((x d-b)) 'd-b)
(defvar *dc* (make-instance 'd-c))
(show (pick *dc*))
(defclass d-c (d-b) ())
(show (pick *dc*))

;;; A method added to the initialization protocol makes the cached
;;; MAKE-INSTANCE fast-path decision out of date.
(defclass ctor () ((s :initarg :s :initform 1 :accessor ctor-s)))
(show (ctor-s (make-instance 'ctor :s 5)))
(defvar *init-version* (version :initialization :all))
(defmethod initialize-instance :after ((o ctor) &rest args)
  (declare (ignore args))
  (setf (ctor-s o) (+ (ctor-s o) 100)))
(show (list (< *init-version* (version :initialization :all))
            (ctor-s (make-instance 'ctor :s 5))))

;;; A method added or removed changes the generic function's assumption.
(defgeneric mgf (x))
(defmethod mgf ((x integer)) (* 2 x))
(defvar *methods-version* (version :methods #'mgf))
(defmethod mgf ((x string)) x)
(show (< *methods-version* (version :methods #'mgf)))
(show (list (mgf 3) (mgf "s")))
(remove-method #'mgf (find-method #'mgf '() (list (find-class 'string))))
(show (< *methods-version* (version :methods #'mgf)))

;;; New assumptions start at version 0, and the listing has the ones with
;;; cells.
(show (list (eql 0 (version :function 'assumption-test-unused))
            (not (null (assumption-entry :class *va-class*)))))
