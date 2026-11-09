(cl:in-package #:clostrophilia)

(define-condition no-applicable-method-error (error)
  ((%function
    :initarg :function
    :reader no-applicable-method-error-function)
   (%arguments
    :initarg :arguments :reader arguments))
  (:report (lambda (condition stream)
             (format stream
                     "Attempt to invoke the following generic function:~@
                      ~s
                      on the following arguments:~@
                      ~s
                      but the function has no method that is applicalble~@
                      to those arguments."
                     (no-applicable-method-error-function condition)
                     (arguments condition)))))

(define-condition method-lambda-list-mismatch (program-error)
  ((%generic-lambda-list :initarg :generic-lambda-list :reader mismatch-generic-lambda-list)
   (%method-lambda-list :initarg :method-lambda-list :reader mismatch-method-lambda-list))
  (:report (lambda (condition stream)
             (format stream "Method lambda list ~S is not congruent with ~S."
                     (mismatch-method-lambda-list condition)
                     (mismatch-generic-lambda-list condition)))))

(define-condition invalid-generic-function-arguments (program-error)
  ((%generic-function :initarg :generic-function :reader invalid-call-generic-function)
   (%arguments :initarg :arguments :reader invalid-call-arguments))
  (:report (lambda (condition stream)
             (format stream "Invalid arguments ~S for generic function ~S."
                     (invalid-call-arguments condition)
                     (generic-function-name (invalid-call-generic-function condition))))))
