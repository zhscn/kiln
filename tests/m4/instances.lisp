;; Instance representation primitives (docs/10 §3).
(defvar *i* (%primop :allocate-general-instance 'my-class 4))
(%primop :set-standard-instance-access *i* -2 17)          ; stamp
(%primop :set-standard-instance-access *i* -1 '(a b))      ; slot list
(%primop :set-standard-instance-access *i* 0 "slot zero")
(%primop :set-standard-instance-access *i* 1 (list 1 2 3))
(%gc)
(print (list (%primop :instance-class *i*)
             (%primop :standard-instance-access *i* -2)
             (%primop :standard-instance-access *i* -1)
             (%primop :standard-instance-access *i* 0)
             (%primop :standard-instance-access *i* 1)))
(print (list (%primop :standard-instance-p *i*) (functionp *i*)))

;; A new rack replaces the old one in one store: the object stays the same.
(let ((other (%primop :allocate-general-instance 'other-class 3)))
  (%primop :set-standard-instance-access other 0 'moved)
  (%primop :set-instance-rack *i* (%primop :instance-rack other))
  (print (list (%primop :instance-class *i*) (%primop :standard-instance-access *i* 0))))

;; Funcallable instances are functions.
(defvar *f* (%primop :allocate-general-funcallable-instance 'gf-class 3))
(%primop :set-standard-instance-access *f* 0 'gf-slot)
(%primop :set-funcallable-instance-function *f* (lambda (&rest args) (cons 'called args)))
(%gc)
(print (functionp *f*))
(print (funcall *f*))
(print (funcall *f* 1 2 3))
(print (funcall *f* 1 2 3 4 5 6))   ; arguments in the transfer area pass through
(print (apply *f* 'a '(b c d e)))
(print (multiple-value-call *f* (values 1 2) (values 3 4)))
(print (mapcar *f* '(x y)))
(print (%primop :standard-instance-access *f* 0))
(%primop :set-funcallable-instance-function *f* (lambda (x) (values x (* x 2))))
(print (multiple-value-list (funcall *f* 21)))
