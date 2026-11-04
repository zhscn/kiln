;;;; closer-mop for the target (docs/10 §20). Libraries that use
;;;; closer-mop are read with the host's CLOSER-MOP package; the
;;;; symbols they name get the functions and classes of Clostrophilia's
;;;; symbols of the same name (front.lisp, EXPAND-CLOSER-MOP-ALIASES).

(in-package #:kiln.kernel)

(defun kiln.sys::%alias-names (pairs)
  "PAIRS: conses (ALIAS . NAME). ALIAS gets the function, SETF function
and class that NAME has."
  (dolist (pair pairs)
    (let ((alias (car pair))
          (name (cdr pair)))
      (when (and (fboundp name) (not (macro-function name)))
        (setf (fdefinition alias) (fdefinition name)))
      (when (fboundp (list 'setf name))
        (setf (fdefinition (list 'setf alias)) (fdefinition (list 'setf name))))
      (let ((class (find-class name nil)))
        (when class
          (setf (find-class alias) class))))))

(kiln.sys::closer-mop-aliases)
