;;;; Editor front ends accept edit requests through an ordered hook list.

(in-package #:kiln.kernel)

(defvar kiln.sys:*ed-functions* nil
  "Functions called by ED with its original argument, until one accepts it.
An accepting function returns non-NIL; filesystem failures signal FILE-ERROR.")

(defun ed (&optional object)
  "Requests editing through KILN.SYS:*ED-FUNCTIONS*, returning T on acceptance."
  (dolist (function kiln.sys:*ed-functions*)
    (when (funcall function object)
      (return-from ed t)))
  (error "No editor accepted the request ~S." object))
