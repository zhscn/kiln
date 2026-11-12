;;;; Native machine code inspection, including HIR evaluator closures.

(in-package #:kiln.kernel)

(defun disassemble (designator)
  (let ((function
          (cond ((functionp designator) designator)
                ((or (symbolp designator) (setf-function-name-p designator))
                 (fdefinition designator))
                ((and (consp designator) (eq (car designator) 'lambda))
                 (compile nil designator))
                (t (error 'type-error :datum designator
                                     :expected-type '(or function symbol
                                                      (cons (eql setf) (cons symbol null))
                                                      (cons (eql lambda) list)))))))
    (let ((text (sys-string 23 function)))
      (unless (stringp text)
        (error "No registered machine code for ~S." function))
      (format t "~&; Machine code for ~S~%~A" function text)))
  nil)
