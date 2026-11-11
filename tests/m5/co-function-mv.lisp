(let ((function
        (compile nil
                 '(lambda (flag)
                    (flet ((target (x) (+ x 10)))
                      (declare (notinline target))
                      (multiple-value-bind (f extra)
                          (if flag (values #'target 1) (values #'target 2))
                        (list (funcall f 3) extra)))))))
  (print (funcall function t))
  (print (funcall function nil)))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((current #'target))
    (multiple-value-bind (f extra)
        (values current (progn (setq current #'other) 7))
      (kiln.sys:%gc)
      (print (list (funcall f 3) (funcall current 4) extra)))))

(flet ((target (x) (+ x 10)))
  (declare (notinline target))
  (multiple-value-bind (f extra)
      (block done
        (unwind-protect (return-from done (values #'target 9))
          (kiln.sys:%gc) (values 17 18 19)))
    (print (list (funcall f 3) extra))))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (multiple-value-bind (f extra) (values #'target #'other)
    (print (list (funcall f 3) (funcall extra 4)))))

(multiple-value-bind (first second) (values)
  (print (list first second)))

(flet ((target (x) (+ x 10)))
  (declare (notinline target))
  (locally (declare (notinline values))
    (multiple-value-bind (f extra) (values #'target 9)
      (print (list (funcall f 3) extra)))))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((current #'target))
    (block done
      (multiple-value-bind (f extra)
          (progn (return-from done) (values #'other 9))
        (declare (ignore f extra)) (setq current #'other)))
    (print (funcall current 3))))
