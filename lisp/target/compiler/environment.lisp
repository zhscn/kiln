;;;; The compiler module's Trucler environments: MACRO-FUNCTION
;;;; and MACROEXPAND with an environment of Common-boot (a
;;;; TRUCLER-REFERENCE:ENVIRONMENT) query it with a reference client.

(in-package #:kiln.eval)

(defvar *reference-client* (make-instance 'trucler-reference:client))

(defmethod environment-client ((environment trucler-reference:environment))
  *reference-client*)
