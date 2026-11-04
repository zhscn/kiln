;;; After the switchover: the full protocol for programs (MAKE-INSTANCE
;;; with INITIALIZE-INSTANCE, finalization, ADD-METHOD, the real
;;; discriminating functions and effective methods).

(defclass shape ()
  ((name :initarg :name :reader shape-name)
   (area :accessor shape-area)
   (tags :initform '() :initarg :tags :accessor shape-tags))
  (:default-initargs :name "anonymous"))

(defclass rect (shape)
  ((w :initarg :w :reader rect-w)
   (h :initarg :h :reader rect-h)))

(defmethod initialize-instance :after ((r rect) &key)
  (setf (shape-area r) (* (rect-w r) (rect-h r))))

(let ((r (make-instance 'rect :w 3 :h 4)))
  (print (list (shape-name r) (shape-area r) (shape-tags r)))
  (reinitialize-instance r :name "box" :tags '(a b))
  (print (list (shape-name r) (shape-area r) (shape-tags r)))
  (print (slot-boundp (make-instance 'shape) 'area)))

;;; Short-form method combinations.

(defgeneric describe-all (x)
  (:method-combination list))
(defmethod describe-all list ((x shape)) 'shape)
(defmethod describe-all list ((x rect)) 'rect)
(defmethod describe-all list ((x t)) 'object)
(print (describe-all (make-instance 'rect :w 1 :h 1)))
(print (describe-all 5))

(defgeneric weight (x)
  (:method-combination +))
(defmethod weight + ((x shape)) 10)
(defmethod weight + ((x rect)) 1)
(print (weight (make-instance 'rect :w 1 :h 1)))

(defgeneric visit (x)
  (:method-combination progn :most-specific-last))
(defmethod visit progn ((x shape)) (print 'visit-shape))
(defmethod visit progn ((x rect)) (print 'visit-rect))
(visit (make-instance 'rect :w 1 :h 1))

(defgeneric check (x)
  (:method-combination and))
(defmethod check and ((x shape)) (print 'check-shape) t)
(defmethod check and ((x rect)) (print 'check-rect) nil)
(print (check (make-instance 'rect :w 1 :h 1)))

;;; Many classes through one generic function: the automaton.

(defgeneric kind (x))
(defmethod kind ((x integer)) 'integer)
(defmethod kind ((x fixnum)) (list 'fixnum (call-next-method)))
(defmethod kind ((x string)) 'string)
(defmethod kind ((x symbol)) 'symbol)
(defmethod kind ((x null)) (list 'null (call-next-method)))
(defmethod kind ((x cons)) 'cons)
(defmethod kind ((x shape)) 'shape)
(defmethod kind ((x (eql :special))) (list 'special (call-next-method)))
(defmethod kind (x) 'other)
(dolist (x (list 1 (expt 2 80) "s" 'a nil '(1) (make-instance 'shape)
                 (make-instance 'rect :w 1 :h 2) :special :plain 1.5 #\c))
  (print (kind x)))

;;; A class defined after the methods.

(defclass square (rect) ())
(defmethod initialize-instance :after ((s square) &key)
  (push 'square (shape-tags s)))
(let ((s (make-instance 'square :w 2 :h 2)))
  (print (list (kind s) (describe-all s) (shape-area s) (shape-tags s))))

;;; Two specialized arguments, an :around method, setf generic functions.

(defgeneric combine (a b))
(defmethod combine ((a integer) (b integer)) (+ a b))
(defmethod combine ((a string) (b string)) (concatenate 'string a b))
(defmethod combine ((a integer) (b string)) (list a b))
(defmethod combine :around ((a integer) b) (list 'around (call-next-method)))
(print (list (combine 1 2) (combine "a" "b") (combine 3 "c")))

(defgeneric (setf size) (value shape))
(defmethod (setf size) (value (r rect))
  (setf (shape-area r) (* value value)))
(let ((r (make-instance 'rect :w 1 :h 1)))
  (setf (size r) 5)
  (print (shape-area r)))

(print (length (clostrophilia::generic-function-methods #'kind)))
(print (mapcar #'class-name (clostrophilia:class-direct-subclasses (find-class 'rect))))
(print (clostrophilia:class-finalized-p (find-class 'square)))
