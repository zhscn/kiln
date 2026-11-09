(cl:in-package #:common-macro-definitions)

(defun check-defgeneric-options-and-methods (options-and-methods)
  (let ((seen nil))
    (dolist (option options-and-methods)
      (unless (and (consp option) (ecc:proper-list-p option))
        (error 'option-or-method-must-be-non-empty-list :expression option))
      (let ((name (first option)))
        (unless (and (member name '(:argument-precedence-order declare :documentation
                                   :method-combination :generic-function-class :method-class :method))
                     (or (member name '(:method declare)) (not (member name seen)))
                     (or (not (member name '(:documentation :generic-function-class :method-class)))
                         (= (length option) 2)))
          (error 'invalid-defgeneric-option :option option))
        (when (and (member name '(:generic-function-class :method-class :method-combination))
                   (or (< (length option) 2) (null (second option))
                       (not (symbolp (second option)))))
          (error 'invalid-defgeneric-option :option option))
        (when (and (eq name :documentation) (not (stringp (second option))))
          (error 'invalid-defgeneric-option :option option))
        (push name seen)))))

(defun separate-options-and-methods (options-and-methods)
  (values (remove :method options-and-methods
                  :key #'car :test #'eq)
          (remove :method options-and-methods
                  :key #'car :test-not #'eq)))

(defgeneric defgeneric-methods-form (client generic-function methods)
  (:method (client generic-function methods)
    (declare (ignore client))
    `(progn ,@methods ,generic-function)))

(defun expand-defgeneric
    (name lambda-list options-and-methods
     compile-time-action ensure-generic-function)
  (check-defgeneric-options-and-methods options-and-methods)
  (multiple-value-bind (options methods)
      (separate-options-and-methods options-and-methods)
    (let* ((method-combination-option
             (assoc :method-combination options))
           (method-combination-name
             (if (null method-combination-option)
                 nil
                 (second method-combination-option)))
           (method-combination-arguments
             (if (null method-combination-option)
                 '()
                 (rest (rest method-combination-option))))
           (argument-precedence-order
             (assoc :argument-precedence-order options))
           (generic-function-class-option
             (assoc :generic-function-class options))
           (generic-function-class-name
             (if (null generic-function-class-option)
                 nil
                 (second generic-function-class-option)))
           (method-class-option
             (assoc :method-class options))
           (method-class-name
             (if (null method-class-option)
                 nil
                 (second method-class-option)))
           (documentation-option
             (assoc :documentation options))
           (result (gensym "GENERIC-FUNCTION")))
      `(progn
         (eval-when (:compile-toplevel)
           ,(funcall compile-time-action
                     name
                     lambda-list
                     argument-precedence-order
                     generic-function-class-name
                     method-class-name
                     method-combination-name
                     method-combination-arguments
                     documentation-option))
         (eval-when (:load-toplevel :execute)
           (let ((,result
                   ,(funcall ensure-generic-function
                             name
                             lambda-list
                             argument-precedence-order
                             generic-function-class-name
                             method-class-name
                             method-combination-name
                             method-combination-arguments
                             documentation-option)))
             ,(defgeneric-methods-form
               *client* result
               (loop for method in methods collect `(defmethod ,name ,@(rest method))))))))))
