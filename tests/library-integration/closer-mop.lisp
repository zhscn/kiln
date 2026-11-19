(in-package #:cl-user)

(defclass closer-mop-probe-base ()
  ((base :initarg :base :reader closer-mop-probe-value)))

(defclass closer-mop-probe (closer-mop-probe-base)
  ((local :initarg :local)))

(let* ((class (find-class 'closer-mop-probe))
       (object (make-instance class :base 41 :local 1)))
  (assert (eq class (closer-mop:ensure-finalized class)))
  (assert (member (find-class 'closer-mop-probe-base)
                  (closer-mop:class-direct-superclasses class)))
  (assert (equal '(local)
                 (mapcar #'closer-mop:slot-definition-name
                         (closer-mop:class-direct-slots class))))
  (let ((slots (mapcar #'closer-mop:slot-definition-name
                       (closer-mop:class-slots class))))
    (assert (and (= (length slots) 2) (member 'base slots) (member 'local slots))))
  (assert (= 42 (+ (closer-mop-probe-value object) (slot-value object 'local)))))
