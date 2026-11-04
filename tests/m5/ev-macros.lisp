;;; The standard macros at run time (the eval module, docs/11 §3).
(dolist (name '(when unless cond case and or dolist dotimes do setf push incf
                defun defmacro defvar defparameter defclass defgeneric defmethod
                destructuring-bind multiple-value-bind handler-case restart-case
                with-output-to-string loop define-condition do-symbols assert
                defpackage in-package))
  (unless (macro-function name)
    (print (list 'no-macro name))))
(print (macroexpand-1 '(when a b c)))
(print (macroexpand-1 '(unless a b)))
;; Gensym names do not depend on what ran at load time.
(setq *gensym-counter* 1000)
(print (macroexpand '(push x (car y))))
(print (macroexpand '(setf (getf plist :k) 3)))
(print (macroexpand-1 '(defun f (x) (1+ x))))
(multiple-value-bind (vars vals stores store access) (get-setf-expansion '(car x))
  (print (list (length vars) vals (length stores) (car store) (car access))))
;; A macro defined at run time with DEFMACRO's expansion.
(setf (macro-function 'my-twice)
      (lambda (form env) (declare (ignore env)) `(progn ,(second form) ,(second form))))
(print (macroexpand-1 '(my-twice (incf n))))
