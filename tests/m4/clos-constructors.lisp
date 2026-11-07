;;; MAKE-INSTANCE's fast path (constructors.lisp) and when it must not be
;;; taken: methods on INITIALIZE-INSTANCE, SHARED-INITIALIZE and
;;; ALLOCATE-INSTANCE, default initargs, and methods added later.

(defun show (x) (write-line (prin1-to-string x)))

(defclass plain () ((a :initarg :a :initform 1 :accessor a) (b :initarg :b :accessor b)))
(defclass defaulted (plain) () (:default-initargs :b 'default-b))
(let ((p (make-instance 'plain :b 2)) (d (make-instance 'defaulted)))
  (show (list (a p) (b p) (a d) (b d) (slot-boundp (make-instance 'plain) 'b))))

(defclass counted (plain) ())
(defvar *count* 0)
(make-instance 'counted)
(defmethod initialize-instance :after ((c counted) &key)
  (incf *count*))
(make-instance 'counted)
(make-instance 'counted)
(show *count*)

(defclass shared (plain) ())
(make-instance 'shared)
(defmethod shared-initialize :before ((s shared) slots &key)
  (declare (ignore slots))
  (incf *count* 10))
(make-instance 'shared :a 5)
(show *count*)

;; A method on a superclass reaches the subclasses already made.
(defclass sub (plain) ())
(make-instance 'sub)
(defmethod initialize-instance :around ((p plain) &key)
  (incf *count* 100)
  (call-next-method))
(make-instance 'sub)
(show *count*)
(remove-method #'initialize-instance
               (find-method #'initialize-instance '(:around) (list (find-class 'plain))))
(make-instance 'sub)
(show *count*)

;; Redefinition changes the default initargs.
(defclass redef () ((x :initarg :x :accessor x)) (:default-initargs :x 1))
(show (x (make-instance 'redef)))
(defclass redef () ((x :initarg :x :accessor x)) (:default-initargs :x 2))
(show (x (make-instance 'redef)))
