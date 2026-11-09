;;; CALL-NEXT-METHOD and NEXT-METHOD-P in their forms: no arguments, new
;;; arguments, #'CALL-NEXT-METHOD, APPLY, NEXT-METHOD-P at the end of the
;;; chain, an assigned parameter (no arguments: the original ones); and
;;; generic functions dispatching on two parameters or with &OPTIONAL.

(defclass nm-a () ())
(defclass nm-b (nm-a) ())
(defclass nm-c (nm-b) ())

(defgeneric nm-f (x n))
(defmethod nm-f ((x nm-a) n) (list 'a n))
(defmethod nm-f ((x nm-b) n) (list* 'b (call-next-method x (+ n 1))))
(defmethod nm-f ((x nm-c) n)
  (setq n 100)
  (list* 'c n (call-next-method)))

(defgeneric nm-g (x))
(defmethod nm-g ((x nm-a)) (list 'a (next-method-p)))
(defmethod nm-g ((x nm-b)) (list* 'b (next-method-p) (funcall #'call-next-method)))
(defmethod nm-g ((x nm-c)) (list* 'c (apply #'call-next-method (list x))))

(defgeneric nm-h (x y))
(defmethod nm-h ((x nm-a) (y nm-a)) 'aa)
(defmethod nm-h ((x nm-b) (y nm-a)) (list 'ba (call-next-method)))
(defmethod nm-h ((x nm-a) (y nm-b)) (list 'ab (call-next-method)))

(defgeneric nm-o (x &optional y))
(defmethod nm-o ((x nm-a) &optional (y 1)) (list 'a y))
(defmethod nm-o ((x nm-b) &optional (y 2)) (list* 'b y (call-next-method)))

(let ((a (make-instance 'nm-a)) (b (make-instance 'nm-b)) (c (make-instance 'nm-c)))
  (print (list (nm-f a 1) (nm-f b 1) (nm-f c 1)))
  (print (list (nm-g a) (nm-g b) (nm-g c)))
  (dotimes (i 2)
    (print (list (nm-h a a) (nm-h b a) (nm-h a b) (nm-h b b) (nm-h c c))))
  (dotimes (i 2)
    (print (list (nm-o a) (nm-o b) (nm-o c 5)))))
