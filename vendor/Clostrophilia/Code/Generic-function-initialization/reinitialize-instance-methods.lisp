(cl:in-package #:clostrophilia)

(defmethod reinitialize-instance :before
    ((generic-function generic-function)
     &key
       (method-class nil method-class-p)
       (lambda-list nil lambda-list-p)
     &allow-other-keys)
  (when lambda-list-p
    (dolist (method (generic-function-methods generic-function))
      (check-method-lambda-list lambda-list (method-lambda-list method))))
  (when method-class-p
    (unless (subtypep-1 method-class (find-class 'method))
      (error 'method-class-option-must-be-method-class
             :method-class method-class))))
