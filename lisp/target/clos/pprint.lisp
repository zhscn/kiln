;;;; The pretty printer (docs/10 §25): kiln's client of Inravina,
;;;; intrinsic: PPRINT-LOGICAL-BLOCK, PPRINT-NEWLINE and the other CL
;;;; pretty printing functions, *PRINT-PPRINT-DISPATCH* and the dispatch
;;;; tables are Inravina's. The interface names that are not CL symbols
;;;; (the standard table, PRETTY-STREAM-P) are in INRAVINA-INTRINSIC, as
;;;; upstream's intrinsic interface has them.

(defpackage #:inravina-intrinsic
  (:use #:common-lisp)
  (:export #:*standard-pprint-dispatch*
           #:*initial-pprint-dispatch*
           #:kiln-client
           #:pretty-stream-p))

(in-package #:inravina-intrinsic)

(defclass kiln-client (incless::kiln-client inravina:client) ())

(setf incless::*client* (make-instance 'kiln-client))

(inravina:define-interface :client-form incless::*client* :client-class kiln-client :intrinsic t)

;;; WITH-STANDARD-IO-SYNTAX binds *PRINT-PPRINT-DISPATCH* to it.
(setf kiln.kernel::*standard-pprint-dispatch* *standard-pprint-dispatch*)
