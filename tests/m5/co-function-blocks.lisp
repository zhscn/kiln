(let ((function
        (compile nil
                 '(lambda (flag)
                    (flet ((target (x) (+ x 10)))
                      (declare (notinline target))
                      (let ((f nil))
                        (block choose
                          (setq f #'target)
                          (if flag (return-from choose))
                          (setq f #'target))
                        (kiln.sys:%gc)
                        (funcall f 3)))))))
  (print (funcall function t))
  (print (funcall function nil)))

(let ((function
        (compile nil
                 '(lambda (flag)
                    (flet ((target (x) (+ x 10)) (other (x) (- x 10)))
                      (declare (notinline target other))
                      (let ((f nil))
                        (block choose
                          (if flag (progn (setq f #'target) (return-from choose)))
                          (setq f #'other))
                        (funcall f 3)))))))
  (print (funcall function t))
  (print (funcall function nil)))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((f nil))
    (block outer
      (block inner (setq f #'target) (return-from outer))
      (setq f #'other))
    (print (list (funcall f (progn (setq f #'other) 3)) (funcall f 4)))))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((f #'target))
    (block choose (setq f (progn (return-from choose) #'other)))
    (print (funcall f 3))))

(flet ((target (x) (+ x 10)))
  (declare (notinline target))
  (let ((log nil))
    (let ((f (block choose
               (push :before log)
               (return-from choose #'target)
               (push :unreachable log))))
      (print (list (funcall f 3) log)))))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((f nil))
    (flet ((change () (setq f #'other)))
      (declare (notinline change))
      (block choose (setq f #'target))
      (change)
      (print (funcall f 3)))))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((f nil))
    (block choose (unwind-protect (setq f #'target) (setq f #'other)))
    (print (funcall f 3))))

(let ((f (block choose
           (let ((counter 0))
             (flet ((target (x) (incf counter x)))
               (declare (notinline target))
               (return-from choose #'target))))))
  (kiln.sys:%gc)
  (print (list (funcall f 3) (funcall f 4))))
