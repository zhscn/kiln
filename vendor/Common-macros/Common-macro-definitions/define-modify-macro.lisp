(cl:in-package #:common-macro-definitions)

(defmacro define-modify-macro
    (name lambda-list function &optional documentation)
  (let* ((canonicalized-lambda-list
           (ecclesia:canonicalize-define-modify-macro-lambda-list
            lambda-list))
         (required
           (ecclesia:extract-required
            canonicalized-lambda-list))
         (optionals
           (ecclesia:extract-named-group
            canonicalized-lambda-list '&optional))
         (rest
           (ecclesia:extract-named-group
            canonicalized-lambda-list '&rest))
         (place-var (gensym))
         (environment (gensym "ENV")))
    `(cl:defmacro ,name (,place-var ,@lambda-list &environment ,environment)
       ,@(if (null documentation) '() (list documentation))
       (let ((argument-forms
               (list* ,@required
                      ,@(if (null optionals)
                            '()
                            (mapcar #'first (rest optionals)))
                      ,(if (null rest)
                           '()
                           (second rest)))))
         (multiple-value-bind
               (vars vals store-vars writer-form reader-form)
             (cl:get-setf-expansion ,place-var ,environment)
           ;; This last part would look more "natural" if written
           ;; using the backquote facility, but the problem is that
           ;; the DEFINE-MODIFY-MACRO macro code is read by some
           ;; standard reader R, but the expansion might be processed
           ;; by a different compiler, so the expansion cannot contain
           ;; calls to the backquote macros created by R.
           (let* ((argument-vars (mapcar (lambda (form) (declare (ignore form)) (gensym "ARG"))
                                         argument-forms))
                  (bindings
                   (loop for var in vars
                         for val in vals
                         collect (list var val)))
                 (compute (list* ',function reader-form argument-vars)))
             (list 'let*
                   (append bindings (mapcar #'list argument-vars argument-forms)
                           (list (list (first store-vars) compute))
                           (rest store-vars))
                   writer-form)))))))
