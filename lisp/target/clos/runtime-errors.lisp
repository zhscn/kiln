;;;; Errors detected by compiled code and the runtime become conditions:
;;;; the kernel's %RUNTIME-ERROR, which ended the program,
;;;; now signals a condition for the error code (lisp/abi.lisp).

(in-package #:clostrophilia)

(define-condition kiln-simple-program-error (program-error simple-error) ())

;;; As SBCL's: STORAGE-CONDITION is not an ERROR, so HANDLER-CASE of ERROR
;;; does not catch it.
(define-condition kiln.sys:stack-exhausted (storage-condition) ()
  (:report "Control stack exhausted (no more room for function calls)."))

(defun kiln.kernel::%runtime-error (code object)
  (flet ((type-error (expected-type)
           (error 'type-error :datum object :expected-type expected-type))
         (program-error (control)
           (error 'kiln-simple-program-error
                  :format-control control :format-arguments (list object))))
    (case code
      (1 (type-error 'fixnum))
      (3 (program-error "invalid number of arguments: ~S"))
      (4 (type-error 'list))
      (5 (type-error 'function))
      (6 (error 'undefined-function :name object))
      (7 (error 'unbound-variable :name object))
      (8 (type-error 'symbol))
      (9 (program-error "odd number of keyword arguments: ~S"))
      (10 (program-error "unknown keyword argument ~S"))
      (11 (type-error 'character))
      (12 (type-error 'string))
      (13 (type-error 'simple-vector))
      (14 (type-error 'kiln.kernel::valid-index))
      (15 (type-error 'sequence))
      (16 (type-error 'integer))
      (17 (error 'division-by-zero :operation '/ :operands (list object 0)))
      (18 (type-error 'real))
      (19 (error 'simple-error :format-control "~S is not a known type specifier"
                               :format-arguments (list object)))
      (21 (error 'undefined-function :name (list 'setf object)))
      (22 (error 'kiln.sys:stack-exhausted))
      (t (kiln.sys:%primop :fatal-error code object)))))

;;; What the expansions of Common-macros' macros signal or call at run time.

(define-condition common-macro-definitions::ecase-type-error (type-error) ())
(define-condition common-macro-definitions::ccase-type-error (type-error) ())
(define-condition common-macro-definitions::etypecase-type-error (type-error) ())
(define-condition common-macro-definitions::ctypecase-type-error (type-error) ())
(define-condition common-macro-definitions::both-test-and-test-not-given (error) ())

(defun common-macro-definitions::store-value-read-evaluated-form ()
  (format *query-io* "~&;; Type a form to be evaluated:~%")
  (list (eval (read *query-io*))))

(defun common-macro-definitions::check-type-error (place value type type-string)
  (restart-case
      (error 'simple-type-error
             :datum value
             :expected-type type
             :format-control (if type-string
                                 "The value of ~S is ~S, which is not ~A."
                                 "The value of ~S is ~S, which is not of type ~S.")
             :format-arguments (list place value (or type-string type)))
    (store-value (new-value)
      :report (lambda (stream)
                (format stream "Supply a new value of ~S." place))
      :interactive common-macro-definitions::store-value-read-evaluated-form
      new-value)))
