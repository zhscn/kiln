;;;; Descriptions use the public object protocols and an extensible generic function.

(in-package #:kiln.kernel)

(defgeneric describe-object (object stream))

(defmethod describe-object ((object t) stream)
  (format stream "~&Object of type ~S~%" (type-of object))
  (unless (arrayp object)
    (format stream "Value: ~S~%" object))
  (typecase object
    (array
     (format stream "Dimensions: ~S~%Element type: ~S~%Adjustable: ~S~%"
             (array-dimensions object) (array-element-type object)
             (adjustable-array-p object))
     (when (array-element-type object)
       (format stream "Contents: ~S~%" object)))
    (hash-table
     (format stream "Test: ~S~%Entries: ~D~%Table size: ~D~%"
             (hash-table-test object) (hash-table-count object) (hash-table-size object)))
    (symbol
     (format stream "Name: ~S~%Package: ~S~%" (symbol-name object) (symbol-package object))
     (if (boundp object)
         (format stream "Variable value: ~S~%" (symbol-value object))
         (format stream "Variable is unbound.~%"))
     (cond ((special-operator-p object) (format stream "Special operator.~%"))
           ((macro-function object) (format stream "Macro.~%"))
           ((fboundp object) (format stream "Function is defined.~%"))))
    (generic-function
     (format stream "Name: ~S~%Lambda list: ~S~%Methods: ~D~%"
             (clostrophilia:generic-function-name object)
             (clostrophilia:generic-function-lambda-list object)
             (length (clostrophilia::generic-function-methods object))))
    (function
     (multiple-value-bind (expression closurep name) (function-lambda-expression object)
       (format stream "Name: ~S~%Compiled: ~S~%Closure: ~S~%"
               name (compiled-function-p object) closurep)
       (when expression (format stream "Definition: ~S~%" expression))))
    (pathname
     (format stream "Host: ~S~%Device: ~S~%Directory: ~S~%Name: ~S~%Type: ~S~%Version: ~S~%"
             (pathname-host object) (pathname-device object) (pathname-directory object)
             (pathname-name object) (pathname-type object) (pathname-version object)))
    (package
     (format stream "Name: ~S~%Nicknames: ~S~%Uses: ~S~%"
             (package-name object) (package-nicknames object)
             (mapcar #'package-name (package-use-list object))))
    (standard-object
     (dolist (slot (clostrophilia:class-slots (class-of object)))
       (let ((name (clostrophilia:slot-definition-name slot)))
         (format stream "~S: " name)
         (if (slot-boundp object name)
             (format stream "~S~%" (slot-value object name))
             (format stream "[unbound]~%"))))))
  (values))

(defun describe (object &optional stream)
  (let ((stream (cond ((null stream) *standard-output*)
                      ((eq stream t) *terminal-io*)
                      (t stream)))
        (*print-circle* t)
        (*print-readably* nil)
        (*print-level* (or *print-level* 6))
        (*print-length* (or *print-length* 20)))
    (unless (and (streamp stream) (output-stream-p stream))
      (error 'type-error :datum stream :expected-type '(and stream (satisfies output-stream-p))))
    (describe-object object stream)
    (values)))
