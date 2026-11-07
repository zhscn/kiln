;;; Class redefinition (CLHS 4.3.6): existing instances are updated when
;;; next used (UPDATE-INSTANCE-FOR-REDEFINED-CLASS), subclasses follow,
;;; methods and dispatch see the new class; FIND-METHOD,
;;; MAKE-INSTANCES-OBSOLETE.

(defun show (x) (write-line (prin1-to-string x)))

(defclass rpoint () ((x :initarg :x :accessor rpoint-x) (y :initarg :y :accessor rpoint-y)))
(defclass rpoint3 (rpoint) ((z :initarg :z :initform 0 :accessor rpoint-z)))
(defgeneric describe-it (p))
(defmethod describe-it ((p rpoint)) (list 'rpoint (rpoint-x p) (rpoint-y p)))

(defvar *p* (make-instance 'rpoint :x 1 :y 2))
(defvar *q* (make-instance 'rpoint3 :x 1 :y 2 :z 3))
(show (list (describe-it *p*) (describe-it *q*) (rpoint-z *q*)))

;; Same definition again: nothing changes for the instances.
(defclass rpoint () ((x :initarg :x :accessor rpoint-x) (y :initarg :y :accessor rpoint-y)))
(show (list (describe-it *p*) (rpoint-x *p*) (rpoint-z *q*)))

;; Y removed, COLOR added with an initform; Y's value goes to the
;; property list.
(defmethod update-instance-for-redefined-class :after
    ((p rpoint) added discarded plist &rest initargs)
  (declare (ignore initargs))
  (show (list 'updating (class-name (class-of p)) added discarded plist)))
(defclass rpoint () ((x :initarg :x :accessor rpoint-x)
                    (color :initarg :color :initform 'red :accessor rpoint-color)))
(show (list (rpoint-x *p*) (rpoint-color *p*) (slot-boundp *p* 'x)
            (slot-exists-p *p* 'y)))
(show (list (rpoint-color *q*) (rpoint-z *q*) (rpoint-x *q*)))
(show (handler-case (rpoint-y *p*) (error () 'no-rpoint-y)))
(defmethod describe-it ((p rpoint)) (list 'rpoint (rpoint-x p)))
(show (describe-it (make-instance 'rpoint :x 5)))

;; A new superclass: methods on it apply.
(defclass named () ((name :initarg :name :initform "anon" :reader name-of)))
(defclass rpoint (named) ((x :initarg :x :accessor rpoint-x)))
(defmethod describe-it ((n named)) (list 'named (name-of n)))
(show (list (name-of *p*) (subtypep 'rpoint 'named) (subtypep 'rpoint3 'named)
            (name-of *q*) (describe-it *p*) (describe-it *q*)))

;; FIND-METHOD and MAKE-INSTANCES-OBSOLETE.
(show (list (not (null (find-method #'describe-it '() (list (find-class 'rpoint)))))
            (find-method #'describe-it '() (list (find-class 'rpoint3)) nil)))
(defvar *r* (make-instance 'rpoint3 :x 7))
(make-instances-obsolete 'rpoint3)
(show (list (rpoint-x *r*) (rpoint-z *r*)))

;; Redefinition many times over, as cl-bench's CLOS benchmark.
(dotimes (i 5)
  (defclass bench-a () ((s :initarg :s :initform 1 :accessor bench-s)))
  (defclass bench-b (bench-a) ()))
(show (bench-s (make-instance 'bench-b)))
