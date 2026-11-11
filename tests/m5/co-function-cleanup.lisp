(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((f nil))
    (tagbody
       (unwind-protect (progn (setq f #'target) (go use)) (setq f #'other))
     use (print (funcall f 3)))))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((f nil))
    (unwind-protect
         (tagbody
            (setq f #'target) (go use)
          use (print (funcall f 3)))
      (setq f #'other))
    (print (funcall f 4))))

(let ((function
        (compile nil
                 '(lambda ()
                    (flet ((target (x) (+ x 10)) (other (x) (- x 10)))
                      (declare (notinline target other))
                      (let ((f nil))
                        (let ((chosen (block done
                                        (unwind-protect (return-from done #'target)
                                          (setq f #'other)
                                          (kiln.sys:%gc)))))
                          (list (funcall chosen 3) (funcall f 4)))))))))
  (print (funcall function)))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((f nil))
    (let ((chosen (block done
                    (unwind-protect (return-from done #'target)
                      (setq f #'other) (return-from done #'other)))))
      (print (list (funcall chosen 3) (funcall f 4))))))

(defun function-cleanup-throw (flag)
  (if flag (throw 'tag :caught)))
(let ((function
        (compile nil
                 '(lambda (flag)
                    (flet ((target (x) (+ x 10)) (other (x) (- x 10)))
                      (declare (notinline target other))
                      (let ((f #'other))
                        (block done (catch 'tag
                          (tagbody
                             (unwind-protect
                                  (progn (function-cleanup-throw flag) (setq f #'target))
                               (kiln.sys:%gc) (go use))
                           use (return-from done (funcall f 3)))))))))))
  (print (funcall function t))
  (print (funcall function nil)))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((f nil) (count 0) (result nil))
    (tagbody again
       (unwind-protect
            (unwind-protect (progn (setq f #'target) (go use))
              (setq f #'other))
         (setq f #'target))
     use
       (push (funcall f count) result)
       (incf count)
       (if (< count 3) (go again)))
    (print (nreverse result))))

(let ((saved nil))
  (unwind-protect (identity nil)
    (let ((counter 0))
      (flet ((next (x) (incf counter x)))
        (declare (notinline next))
        (setq saved #'next))))
  (kiln.sys:%gc)
  (print (list (funcall saved 3) (funcall saved 4))))
