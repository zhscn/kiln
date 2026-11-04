;;;; The eval module (docs/11 §3, M5.1): the standard macros at run time,
;;;; then Maclina's evaluator.
;;;;
;;;; Common-macros is compiled for the target with its package renamed to
;;;; KILN.CMD (the host's COMMON-MACRO-DEFINITIONS is the extrinsic one the
;;;; compiler uses). KILN.CMD uses CL and shadows only the functions whose
;;;; Common-macros versions take a client, so its macros are CL's
;;;; (Common-macros' own intrinsic package shadows too little: vendor/README.md).
;;;; kiln's client (macro-client.lisp) is read again in KILN.MACROS-TARGET,
;;;; where CMD names KILN.CMD.

(defpackage #:kiln.cmd
  (:use #:common-lisp)
  (:local-nicknames (#:ecc #:ecclesia))
  (:shadow #:get-setf-expansion #:ensure-generic-function #:proclaim)
  (:export #:*client* #:get-setf-expansion #:defun-compile-time-action
           #:add-local-nickname #:defclass-compile-time-action #:ensure-class-name
           #:defgeneric-compile-time-action #:ensure-generic-function
           #:setf-type-function-wrapper #:proclaim #:make-method-lambda-wrapper
           #:ensure-method-wrapper #:wrap-in-setf-setf-expander))

(defpackage #:kiln.macros-target
  (:use #:cl)
  (:local-nicknames (#:cmd #:kiln.cmd))
  (:export #:macro-client))

(in-package #:kiln.kernel)

;;; Common-macros' Low files refer to *CLIENT*, which its shared files
;;; define later.
(defvar kiln.cmd:*client* nil)

;;; The macros that kiln's own modules define (LOOP, DEFINE-CONDITION,
;;; DO-SYMBOLS, ...) win over Common-macros': saved here, restored after it
;;; (macros.lisp).
(defvar *kiln-macros*
  (let ((saved '()))
    (do-external-symbols (s '#:common-lisp)
      (let ((f (macro-function s)))
        (when f (push (cons s f) saved))))
    saved))
