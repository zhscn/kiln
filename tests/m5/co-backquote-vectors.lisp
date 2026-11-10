;;; Commas inside vectors remain active when the vector is nested in a list.
(print `(#(,1)))
(print `(#(#(,1))))
(print `(a . #(,1)))
(let ((count 0) (items (list 2 3)))
  (print `(#(,(incf count) ,@items)))
  (print count)
  (print items))

;;; Both evaluators expand reader-produced forms with the same semantics.
(dolist (native '(nil t))
  (let ((kiln.kernel::*eval-function* (and native 'kiln.compiler::native-eval))
        (kiln.kernel::*compile-function* (and native 'kiln.compiler::native-compile)))
    (dolist (input '("`(#(,1))" "`(#(,@'(1 2)))" "`(#(,.'(1 2)))"
                     "`(#(#(,1)))" "`(a . #(,1))"))
      (print (eval (read-from-string input))))))
