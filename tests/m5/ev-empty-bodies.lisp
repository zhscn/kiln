(dolist (form '((progn) (eval-when (:execute)) (setf) (progn (values))))
  (print (multiple-value-list (eval form))))
