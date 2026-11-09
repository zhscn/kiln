(cl:in-package #:clostrophilia)

;;; This function takes a method and, if it is a standard reader
;;; method or a standard writer method, it replaces it with a method
;;; that does a direct instance access according to the relevant class
;;; in CLASSES.  Otherwise, it returns the METHOD argument unchanged.
(defun maybe-replace-method (method classes)
  (let ((method-class (physical-class-of method)))
    (flet ((slot-location (direct-slot class)
             (let* ((name (slot-definition-name direct-slot))
                    (effective-slots (class-slots class))
                    (effective-slot (find name effective-slots
                                          :key #'slot-definition-name
                                          :test #'eq)))
               (slot-definition-location effective-slot))))
      (cond ((eq method-class
                 (find-class 'standard-reader-method))
             (let* ((direct-slot (accessor-method-slot-definition method))
                    (location (slot-location direct-slot (car classes)))
                    (lambda-expression
                      `(lambda (arguments next-methods)
                         (declare (ignorable arguments next-methods))
                         ,(if (consp location)
                              `(car ',location)
                              `(slot-value-using-location+1
                                (car arguments) ,location)))))
               (make-instance
                   (find-class 'standard-reader-method)
                 :qualifiers '()
                 :specializers (method-specializers method)
                 :lambda-list (method-lambda-list method)
                 :slot-location location
                 :slot-definition direct-slot
                 :documentation nil
                 ;; kiln: a closure, not a compiled lambda expression.
                 :function (if (consp location)
                               (lambda (arguments next-methods)
                                 (declare (ignore arguments next-methods))
                                 (car location))
                               (lambda (arguments next-methods)
                                 (declare (ignore next-methods))
                                 (slot-value-using-location+1 (car arguments) location))))))
            ((eq method-class (find-class 'standard-writer-method))
             (let* ((direct-slot (accessor-method-slot-definition method))
                    (location (slot-location direct-slot (cadr classes)))
                    (lambda-expression
                      `(lambda (arguments next-methods)
                         (declare (ignorable arguments next-methods))
                         ,(if (consp location)
                              `(setf (car ',location)
                                     (car arguments))
                              `(setf (slot-value-using-location+1
                                      (cadr arguments) ,location)
                                     (car arguments))))))
               (make-instance
                   (find-class 'standard-writer-method)
                 :qualifiers '()
                 :specializers (method-specializers method)
                 :lambda-list (method-lambda-list method)
                 :slot-location location
                 :slot-definition direct-slot
                 :documentation nil
                 ;; kiln: a closure, not a compiled lambda expression.
                 :function (if (consp location)
                               (lambda (arguments next-methods)
                                 (declare (ignore next-methods))
                                 (setf (car location) (car arguments)))
                               (lambda (arguments next-methods)
                                 (declare (ignore next-methods))
                                 (setf (slot-value-using-location+1 (cadr arguments) location)
                                       (car arguments)))))))
            (t
             method)))))
