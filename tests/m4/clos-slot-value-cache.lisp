;;; SLOT-VALUE and (SETF SLOT-VALUE) with a constant slot name at a call
;;; site: the location is cached by the object's stamp (a class has one
;;; layout for one stamp). The cache must follow subclasses, class
;;; redefinition, CHANGE-CLASS, class-allocated slots, unbound slots and
;;; structures, which go SLOT-VALUE's own way.

(defun show (x) (write-line (prin1-to-string x)))

(defclass sv-point () ((x :initarg :x) (y :initarg :y)))
(defclass sv-point3 (sv-point) ((z :initarg :z)))

(defvar *p* (make-instance 'sv-point :x 1 :y 2))
(defvar *q* (make-instance 'sv-point :x 3 :y 4))
(defvar *r* (make-instance 'sv-point3 :x 5 :y 6 :z 7))

;; Twice: the second time from the cache. Another instance of the class
;; hits it too; an instance of the subclass misses it.
(show (list (slot-value *p* 'x) (slot-value *p* 'x) (slot-value *q* 'x)
            (slot-value *r* 'x) (slot-value *r* 'z)))

;; A call site that sees two classes in turn.
(defun sv-x (object) (slot-value object 'x))
(defvar *s* (make-instance 'sv-point3 :x 8 :y 9 :z 10))
(show (list (sv-x *p*) (sv-x *s*) (sv-x *q*) (sv-x *s*)))

;; (SETF SLOT-VALUE), twice each.
(defclass sv-counter () ((value :initform 0)))
(defvar *counter* (make-instance 'sv-counter))
(show (slot-value *counter* 'value))
(setf (slot-value *counter* 'value) 5)
(show (slot-value *counter* 'value))
(setf (slot-value *counter* 'value) 6)
(show (slot-value *counter* 'value))
(handler-case (slot-value *counter* 'no-such-slot) (error () (show :no-slot)))

;; A slot that is unbound: SLOT-VALUE signals, SETF of it works.
(defclass sv-unbound () ((u)))
(defvar *unbound* (make-instance 'sv-unbound))
(show (handler-case (slot-value *unbound* 'u) (error () :unbound)))
(setf (slot-value *unbound* 'u) 1)
(show (slot-value *unbound* 'u))

;; A class-allocated slot: the location is a cons, so the call site goes
;; SLOT-VALUE's way.
(defclass sv-class-slot () ((c :allocation :class :initform 10)))
(defvar *class-slot* (make-instance 'sv-class-slot))
(show (list (slot-value *class-slot* 'c)
            (progn (setf (slot-value *class-slot* 'c) 11)
                   (slot-value (make-instance 'sv-class-slot) 'c))))

;; CHANGE-CLASS: the instance takes the new class's stamp, so the cache
;; misses and finds the slot in the new layout.
(defclass sv-a () ((x :initarg :x)))
(defclass sv-b () ((x :initarg :x) (y :initform 2)))
(defvar *changed* (make-instance 'sv-a :x 1))
(show (slot-value *changed* 'x))
(change-class *changed* 'sv-b)
(show (list (slot-value *changed* 'x) (slot-value *changed* 'y)))

;; Redefinition: the old instance is obsolete until a generic function
;; updates it; then its stamp is the class's new one, and the call site
;; finds the slot's location in the new layout.
(defclass sv-r () ((a :initarg :a) (b :initform 2)))
(defgeneric sv-touch (object))
(defmethod sv-touch ((object sv-r)) (list (slot-value object 'a) (slot-value object 'b)))
(defvar *old* (make-instance 'sv-r :a 1))
(show (sv-touch *old*))
(defclass sv-r () ((b :initform 2) (a :initarg :a)))
(defvar *new* (make-instance 'sv-r :a 3))
(show (list (sv-touch *old*) (sv-touch *new*)))
(show (list (slot-value *old* 'a) (slot-value *new* 'a)))

;; A structure instance: not a standard instance, so SLOT-VALUE's way.
(defstruct sv-struct a b)
(defvar *struct* (make-sv-struct :a 1 :b 2))
(show (list (slot-value *struct* 'a) (slot-value *struct* 'a)
            (progn (setf (slot-value *struct* 'a) 3) (slot-value *struct* 'a))))
