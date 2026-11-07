;;;; Builds the braid from the classes recorded so far: Clostrophilia's
;;;; class hierarchy and kiln's built-in classes. The
;;;; DEFGENERIC and DEFMETHOD forms seen so far take effect now.

(in-package #:clostrophilia)

(build-braid)

(defvar *standard-object* (find-class 'standard-object))
(defvar *funcallable-standard-object* (find-class 'funcallable-standard-object))
(defvar *class-t+1* (find-class 't))
