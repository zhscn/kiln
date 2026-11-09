(cl:in-package #:clostrophilia)

(defun method-combination-argument-binder (lambda-list)
  (let ((whole (and (eq (first lambda-list) '&whole) (second lambda-list)))
        (arguments (gensym "ARGUMENTS"))
        (variables nil) (state :required) (required 0))
    (when whole (setf lambda-list (cddr lambda-list)) (push whole variables))
    (dolist (parameter lambda-list)
      (cond ((member parameter lambda-list-keywords) (setf state parameter))
            ((eq state :required) (incf required) (push parameter variables))
            ((member state '(&optional &key &aux))
             (let ((name (if (consp parameter) (first parameter) parameter)))
               (push (if (consp name) (second name) name) variables)
               (when (and (not (eq state '&aux)) (consp parameter) (third parameter))
                 (push (third parameter) variables))))
            ((eq state '&rest) (push parameter variables))))
    (setf variables (nreverse variables))
    ;; A combination may describe fewer arguments than the generic function.
    (let* ((aux (position '&aux lambda-list))
           (head (subseq lambda-list 0 aux))
           (tail (and aux (subseq lambda-list aux))))
      (unless (or (member '&key head) (member '&rest head))
        (setf head (append head (list '&rest (gensym "UNUSED-ARGUMENTS")))))
      (values variables
              `(lambda (,arguments)
                 (let ,(when whole `((,whole ,arguments)))
                   (apply (lambda (,@head ,@tail) (vector ,@variables))
                          (append ,arguments
                                  (make-list (max 0 (- ,required (length ,arguments))))))))))))

(defun long-form-lambda
    (lambda-list-variables method-group-specifiers declarations body
     arguments-option generic-function-variable)
  (let ((method-list-var (gensym "METHOD-LIST"))
        (generic-function-var (or generic-function-variable (gensym "GENERIC-FUNCTION"))))
    (multiple-value-bind (variables binder)
        (when arguments-option
          (method-combination-argument-binder (rest arguments-option)))
      (let* ((names (loop for variable in variables collect (gensym (symbol-name variable))))
             (form (wrap-body method-list-var method-group-specifiers body)))
        `(lambda (,generic-function-var ,method-list-var ,@lambda-list-variables)
           ,@(unless generic-function-variable `((declare (ignore ,generic-function-var))))
           ,@declarations
           ,(if arguments-option
                `(let ,(loop for variable in variables for name in names
                             collect `(,variable ',name))
                   (list '%method-combination-arguments ,binder ',names ,form))
                form))))))

(defun long-form-expander (name lambda-list method-group-specifiers body)
  (let ((lambda-list-variables
          (ecclesia:extract-lambda-list-variables lambda-list))
        (arguments-option nil) (generic-function-variable nil))
    (loop while (and (consp (first body))
                     (member (caar body) '(:arguments :generic-function)))
          for option = (pop body)
          do (ecase (first option)
               (:arguments
                (when arguments-option (error "Duplicate :ARGUMENTS option."))
                (setf arguments-option option))
               (:generic-function
                (unless (and (= (length option) 2) (symbolp (second option))
                             (second option) (not generic-function-variable))
                  (error "Invalid :GENERIC-FUNCTION option: ~S." option))
                (setf generic-function-variable (second option)))))
    (multiple-value-bind (declarations documentation forms)
        (ecclesia:separate-function-body body)
      `(progn (ensure-method-combination-template
               ',name
               (lambda ,lambda-list (list ,@lambda-list-variables))
               ,(long-form-lambda lambda-list-variables method-group-specifiers
                                  declarations forms arguments-option generic-function-variable)
               :documentation ,documentation)
              ',name))))
