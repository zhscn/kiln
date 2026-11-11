(defun function-catch-throw (flag)
  (if flag (throw 'tag :caught)))

(let ((function
        (compile nil
                 '(lambda (flag)
                    (flet ((target (x) (+ x 10)) (other (x) (- x 10)))
                      (declare (notinline target other))
                      (let ((f #'target))
                        (catch 'tag (function-catch-throw flag) (setq f #'other))
                        (funcall f 3)))))))
  (print (funcall function t))
  (print (funcall function nil)))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((f nil))
    (tagbody
       (catch 'tag (setq f #'target) (go use))
       (setq f #'other)
       (go done)
     use (print (funcall f 3))
     done)))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((f nil))
    (tagbody
       (catch (progn (setq f #'target) (go use) 'tag) (setq f #'other))
       (go done)
     use (print (funcall f 3))
     done)))

(flet ((target (x) (+ x 10)))
  (declare (notinline target))
  (let ((f nil) (count 0) (result nil))
    (tagbody again
       (catch 'tag
         (setq f #'target)
         (kiln.sys:%gc)
         (push (funcall f count) result)
         (incf count)
         (if (< count 3) (go again))))
    (print (nreverse result))))

(flet ((target (x) (+ x 10)) (other (x) (- x 10)))
  (declare (notinline target other))
  (let ((f nil))
    (block done
      (catch 'tag (setq f #'target) (return-from done))
      (setq f #'other))
    (print (funcall f 3))))
