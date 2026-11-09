(cl:in-package #:clostrophilia)

;;; For the specification of this generic function, see
;;; http://www.lispworks.com/documentation/HyperSpec/Body/f_init_i.htm#initialize-instance
(defgeneric initialize-instance
    (instance &rest initargs &key &allow-other-keys))

(defmethod initialize-instance
    ((instance slot-object) &rest initargs)
  (apply #'shared-initialize instance t initargs))
