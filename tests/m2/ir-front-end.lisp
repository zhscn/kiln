;;; Parameter defaults observe the preceding dynamic bindings.
(defvar *argument* 'outside)
(defun special-default (*argument* &optional (copy *argument*))
  (list *argument* copy))
(print (special-default 'inside))
(print *argument*)
(defun optional-special (&optional (*argument* 'optional) (copy *argument*))
  (list *argument* copy))
(print (optional-special))
(defun key-special (&key (*argument* 'keyword) (copy *argument*))
  (list *argument* copy))
(print (key-special))
(defun aux-special (&aux (*argument* 'auxiliary))
  (list *argument* (funcall (lambda () *argument*))))
(print (aux-special))
(print *argument*)

;;; A default closure and the body share a mutable parameter cell.
(defun captured-default (x &optional (reader (lambda () x)))
  (setq x (+ x 1))
  (funcall reader))
(print (captured-default 4))

;;; A closure can escape through an otherwise inlinable single local call.
(defun escaped-through-inline (x)
  (flet ((capture (y) (lambda () (+ x y))))
    (capture 3)))
(print (funcall (escaped-through-inline 7)))

;;; SETF local functions return through a lexically named block.
(flet (((setf local-place) (value object)
         (declare (ignore object))
         (block local-place (return-from local-place value))))
  (print (funcall #'(setf local-place) 9 nil)))

;;; Separate activations share captured cells, but not block tokens.
(let ((result nil))
  (labels ((walk (n)
             (block found
               (if (zerop n)
                   (push (lambda () (return-from found :stale)) result)
                   (funcall (lambda () (return-from found n)))))))
    (print (functionp (car (walk 0))))
    (print (walk 8))))

;;; Macro queries see local functions shadowing macros in &ENVIRONMENT.
(macrolet ((local-value () 42)
           (inspect (&environment environment)
             (list 'quote (not (null (macro-function 'local-value environment))))))
  (let ((scope t))
    (declare (ignore scope))
    (print (inspect)))
  (flet ((local-value () 0))
    (print (inspect))))

;;; LOAD-TIME-VALUE has its own lexical environment and retains its flag.
(defun load-time-closure () (load-time-value (list 'retained) t))
(print (eq (load-time-closure) (load-time-closure)))

(let ((scope t))
  (declare (ignore scope))
  (macrolet ((inspect-form (form)
               (if (consp form) (second form) form)))
    (print (inspect-form (unused 12)))))
