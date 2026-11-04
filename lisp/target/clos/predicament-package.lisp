;;;; The PREDICAMENT package (its own packages-intrinsic.lisp computes the
;;;; export list with #. from the ASDF file, which kiln does not read).
;;;; The list is Predicament's *STRING-DESIGNATORS*.

(cl:in-package #:common-lisp-user)

(defpackage #:predicament
  (:use #:common-lisp)
  (:export
   #:with-simple-restart #:with-condition-restarts #:*break-on-signals*
   #:*debugger-hook* #:restart #:restart-name #:restart-bind #:restart-case
   #:find-restart #:compute-restarts #:handler-bind #:ignore-errors
   #:make-condition #:invoke-debugger #:invoke-restart
   #:invoke-restart-interactively #:signal #:warn #:warning
   #:serious-condition #:style-warning #:break #:error #:cerror
   #:invalid-method-error #:method-combination-error #:cell-error
   #:cell-error-name #:undefined-function #:unbound-variable #:unbound-slot
   #:unbound-slot-instance #:arithmetic-error #:arithmetic-error-operation
   #:arithmetic-error-operands #:division-by-zero #:floating-point-inexact
   #:floating-point-invalid-operation #:floating-point-overflow
   #:floating-point-underflow #:file-error #:file-error-pathname
   #:package-error #:package-error-package #:parse-error
   #:print-not-readable #:print-not-readable-object #:program-error
   #:reader-error #:simple-condition #:simple-condition-format-control
   #:simple-condition-format-arguments #:simple-error #:type-error
   #:type-error-datum #:type-error-expected-type #:simple-type-error
   #:simple-warning #:storage-condition #:stream-error #:stream-error-stream
   #:end-of-file #:control-error #:abort #:muffle-warning #:continue
   #:store-value #:use-value #:assert))
