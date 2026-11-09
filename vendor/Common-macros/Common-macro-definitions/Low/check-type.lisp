(cl:in-package #:common-macro-definitions)

(defun store-value-read-evaluated-form ()
  (format *query-io* "~&;; Type a form to be evaluated:~%")
  (list (eval (read *query-io*))))

(defmacro with-store-value-restart ((temp-var place tag) &body forms)
  (let ((report-var (gensym "STORE-VALUE-REPORT"))
        (new-value-var (gensym "NEW-VALUE"))
        (form-or-forms (if (= 1 (length forms))
                           (first forms)
                           `(progn ,@forms))))
    `(flet ((,report-var (stream)
              (format stream "Supply a new value of ~S." ',place)))
       (restart-case ,form-or-forms
         (store-value (,new-value-var)
           :report ,report-var
           :interactive store-value-read-evaluated-form
           (setf ,temp-var ,new-value-var
                 ,place ,new-value-var)
           (go ,tag))))))

;;; kiln: the restart is in CHECK-TYPE-ERROR so that the expansion has no
;;; closure or non-local exit at the call site.
(defun check-type-error (place value type type-string)
  (restart-case
      (error
       'simple-type-error
       :datum value
       :expected-type type
       :format-control (if type-string
                           "The value of ~S is ~S, which is not ~A."
                           "The value of ~S is ~S, which is not of type ~S.")
       :format-arguments (list place value (or type-string type)))
    (store-value (new-value)
      :report (lambda (stream)
                (format stream "Supply a new value of ~S." place))
      :interactive store-value-read-evaluated-form
      new-value)))

(defmacro check-type (place type &optional type-string)
  (let ((variable (gensym "CHECK-TYPE-VARIABLE")))
    `(let ((,variable ,place))
       (unless (typep ,variable ',type)
         (loop
           (setf ,variable (check-type-error ',place ,variable ',type ,type-string)
                 ,place ,variable)
           (when (typep ,variable ',type)
             (return nil)))))))
