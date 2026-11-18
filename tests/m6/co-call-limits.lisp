(assert (= call-arguments-limit kiln.kir::+backend-argument-limit+))
(assert (= lambda-parameters-limit call-arguments-limit))
(assert (= multiple-values-limit kiln.kir::+backend-value-limit+))
(let* ((objects (loop for i below 1024 collect (list i)))
       (returned (multiple-value-list
                  (catch 'wide
                    (unwind-protect
                         (throw 'wide (values-list objects))
                      (assert (= 0 (length (apply #'list nil))))
                      (kiln.sys:%gc))))))
  (assert (= (length returned) (length objects)))
  (assert (every #'eq returned objects)))
(let ((rows (loop for i below 10000 collect (list i))))
  (flet ((matrix (&rest rows)
           (kiln.sys:%gc)
           (list (length rows) (caar rows) (caar (last rows)))))
    (assert (equal (apply #'matrix rows) '(10000 0 9999)))))
(print :call-limits)
