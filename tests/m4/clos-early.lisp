;;; DEFCLASS, DEFGENERIC and DEFMETHOD in a program, before the
;;; switchover: early classes, MAKE-INSTANCE and dispatch.

(defclass point ()
  ((x :initarg :x :accessor point-x)
   (y :initarg :y :initform 0 :accessor point-y)))

(defclass point3 (point)
  ((z :initarg :z :initform (+ 1 2) :reader point-z)))

(defgeneric describe-it (object))

(defmethod describe-it ((p point))
  (list 'point (point-x p) (point-y p)))

(defmethod describe-it ((p point3))
  (append (call-next-method) (list (point-z p))))

(defmethod describe-it :before ((p point))
  (print 'before))

(defmethod describe-it :after ((p point3))
  (print 'after))

(defmethod describe-it :around ((p point3))
  (list 'around (next-method-p) (call-next-method)))

(defmethod describe-it ((x integer))
  (list 'integer x))

(defmethod describe-it ((x (eql 42)))
  (list 'answer (call-next-method)))

(defmethod describe-it (x)
  (list 'other x))

(defgeneric (setf thing) (value object))
(defmethod (setf thing) (value (p point))
  (setf (point-y p) (* 2 value)))

(let ((p (make-instance 'point :x 1))
      (q (make-instance 'point3 :x 1 :y 2)))
  (print (describe-it p))
  (print (describe-it q))
  (setf (point-x p) 10)
  (print (point-x p))
  (setf (thing p) 21)
  (print (point-y p))
  (print (describe-it 5))
  (print (describe-it 42))
  (print (describe-it "s"))
  (print (slot-value q 'z))
  (setf (slot-value q 'z) 30)
  (print (point-z q))
  (print (slot-boundp (make-instance 'point) 'x))
  (print (class-name (class-of q)))
  (print (mapcar #'class-name (clostrophilia:class-precedence-list (class-of q))))
  (print (mapcar #'clostrophilia:slot-definition-name
                 (clostrophilia:class-slots (class-of q))))
  (print (eq (class-of p) (find-class 'point))))
