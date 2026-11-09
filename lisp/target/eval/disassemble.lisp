;;;; Native machine code and Maclina bytecode inspection.

(in-package #:kiln.kernel)

(defun disassemble-bytecode (function)
  (let* ((template (if (typep function 'maclina.machine:closure)
                       (maclina.machine:template function) function))
         (module (maclina.machine:module template))
         (start (maclina.machine:entry-pc template)))
    (format t "~&; Bytecode for ~S~%" function)
    (maclina.introspect:map-instructions
     (lambda (mnemonic ip longp &rest arguments)
       (format t "~6D: ~A~:[~; LONG~]~{ ~S~}~%" ip mnemonic longp arguments))
     (maclina.machine:bytecode module)
     :start start :end (+ start (maclina.machine:size template)))))

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
    (if (typep function '(or maclina.machine:function maclina.machine:closure))
        (disassemble-bytecode function)
        (let ((text (sys-string 23 function)))
          (unless (stringp text)
            (error "No registered machine code for ~S." function))
          (format t "~&; Machine code for ~S~%~A" function text))))
  nil)
