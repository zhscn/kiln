(let ((parameters (loop repeat 300 collect (gensym))))
  (dolist (operator '(flet labels))
    (print (eval `(,operator ((sum-many ,parameters (+ ,@parameters)))
                    (sum-many ,@(loop repeat 300 collect 1)))))))
(let ((parameters (loop repeat 300 collect (gensym))))
  (print (eval `(let ,(mapcar (lambda (name) `(,name 1)) parameters)
                 (block finish
                   (unwind-protect (return-from finish (+ ,@parameters))
                     (values)))))))
