;;; Function cells of symbols, including NIL's and T's (defined by the
;;; runtime).
(defun f1 (x) x)
(print (list (fboundp 'f1) (fboundp 'no-such-function) (fboundp nil) (fboundp t)))
(print (list (fboundp '(setf no-such-function)) (fboundp '(setf car))))
(let ((s (make-symbol "FRESH")))
  (print (fboundp s))
  (setf (fdefinition s) #'f1)
  (print (list (fboundp s) (funcall s 3))))
