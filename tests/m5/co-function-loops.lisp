(let ((function
        (compile nil
                 '(lambda (limit)
                    (flet ((target (x) (+ x 10)) (other (x) (- x 10)))
                      (declare (notinline target other))
                      (let ((f #'target) (count 0) (result nil))
                        (tagbody again
                           (if (>= count limit) (go done))
                           (push (funcall f count) result)
                           (tagbody
                              (setq f #'other)
                              (incf count)
                              (go again))
                         done)
                        (nreverse result)))))))
  (print (funcall function 0))
  (print (funcall function 3)))

(flet ((target (x) (+ x 10)))
  (declare (notinline target))
  (let ((f nil) (count 0) (result nil))
    (tagbody again
       (setq f #'target)
       (push (funcall f count) result)
       (incf count)
       (if (< count 3) (go again)))
    (kiln.sys:%gc)
    (print (list (nreverse result) (funcall f 4)))))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((f nil) (count 0) (result nil))
    (tagbody again
       (tagbody (setq f #'target) (go use))
       (setq f #'other)
     use
       (push (funcall f count) result)
       (incf count)
       (if (< count 3) (go again)))
    (print (nreverse result))))

(let ((function
        (compile nil
                 '(lambda ()
                    (let ((f nil) (count 0) (result nil))
                      (tagbody again
                         (let ((snapshot count))
                           (flet ((target () snapshot))
                             (declare (notinline target))
                             (if (null f) (setq f #'target))
                             (kiln.sys:%gc)
                             (push (funcall f) result)))
                         (incf count)
                         (if (< count 3) (go again)))
                      (nreverse result))))))
  (print (funcall function)))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((f nil))
    (block done
      (tagbody again
         (setq f #'target)
         (return-from done)
         (setq f #'other)
         (go again)))
    (print (funcall f 3))))
