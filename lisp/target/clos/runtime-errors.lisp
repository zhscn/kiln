;;;; Errors detected by compiled code and the runtime become conditions
;;;; (docs/10 §10): the kernel's %RUNTIME-ERROR, which ended the program,
;;;; now signals a condition for the error code (lisp/abi.lisp).

(in-package #:clostrophilia)

(define-condition kiln-simple-program-error (program-error simple-error) ())

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
      (t (kiln.sys:%primop :fatal-error code object)))))
