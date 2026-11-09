(cl:in-package #:clostrophilia)

;;; This function is called by the method on MAKE-INSTANCE specialized
;;; to CLASS.  Client code will have to define MAKE-INSTANCE
;;; accordinly.

;;; ALLOCATE-INSTANCE finalizes its class before reading the instance
;;; layout. MAKE-INSTANCE also needs finalization before computing the
;;; defaulted initargs, so ALLOCATE-INSTANCE-USING-CLASS does it earlier.

(defun allocate-instance-using-class
    (class
     &rest initargs
     &key (additional-size 0)
     &allow-other-keys)
  (unless (class-finalized-p class)
    (finalize-inheritance class))
  ;; FIXME: check shape of initargs (proper, length is even, etc.).
  (let ((defaulted-initargs initargs))
    (loop with default = (load-time-value (list nil))
          for (name form thunk) in (class-default-initargs class)
          do (when (eq (getf initargs name default) default)
               (setf defaulted-initargs
                     (append defaulted-initargs
                             (list name (funcall thunk))))))
    (values (apply #'allocate-instance class
                   :additional-size additional-size
                   defaulted-initargs)
            defaulted-initargs)))
