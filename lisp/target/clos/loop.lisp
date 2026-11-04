;;;; LOOP (docs/10 §20): Khazern, intrinsic, for the run-time macro
;;;; environment. Code compiled by the cross compiler gets its LOOP
;;;; expansions from the host's Khazern (front.lisp); this module makes
;;;; CL:LOOP and CL:LOOP-FINISH macros of the image, for MACROEXPAND now
;;;; and for the compiler once it runs in kiln.
;;;;
;;;; Khazern's DEFINE-INTERFACE would define them with DEFMACRO, which also
;;;; takes effect at compile time and would replace the host's expander in
;;;; the compile-time environment; so the macro functions are set at load
;;;; time only.

(in-package #:khazern)

(defclass kiln-client (standard-client) ())

(defvar *kiln-client* (make-instance 'kiln-client))

(let ((epilogue-tag (make-symbol "EPILOGUE")))
  (setf (macro-function 'loop-finish)
        (lambda (form environment)
          (declare (ignore form environment))
          `(go ,epilogue-tag)))
  (setf (macro-function 'loop)
        (lambda (form environment)
          (declare (ignore environment))
          (expand-body *kiln-client* (rest form) epilogue-tag))))
