(let ((function
        (compile nil
                 '(lambda (flag value)
                    (declare (double-float value))
                    (let ((log nil))
                      (list (* (unwind-protect
                                    (if flag (1+ value) (1- value))
                                 (push :cleanup log)
                                 (setq value 10d0)
                                 (kiln.sys:%gc))
                               value)
                            (reverse log)))))))
  (print (funcall function t 3d0))
  (print (funcall function nil 3d0)))

(defun double-cleanup-throw (tag) (throw tag :caught))
(let ((count 0) (value 3d0))
  (declare (double-float value))
  (print (catch 'tag
           (* (unwind-protect
                   (progn (double-cleanup-throw 'tag) (1+ value))
                (incf count) (kiln.sys:%gc))
              2d0)))
  (print count))

(print (block done
         (* (unwind-protect (1+ 3d0) (return-from done 17d0)) 2d0)))

(let ((value 3d0) (answer 0d0) (log nil))
  (declare (double-float value answer))
  (catch 'tag
    (tagbody
     (setq answer
           (* (unwind-protect
                   (unwind-protect
                        (progn (double-cleanup-throw 'tag) (1+ value))
                     (push :inner log) (kiln.sys:%gc))
                (push :outer log)
                (setq answer 5d0)
                (go done))
              2d0))
     (setq answer -1d0)
   done))
  (print (list answer (reverse log))))

(print (multiple-value-list
         (unwind-protect (values 1d0 :ok) (kiln.sys:%gc))))

(let ((value 3d0))
  (declare (double-float value))
  (print (* (unwind-protect
                 (unwind-protect (1+ value)
                   (setq value 20d0) (kiln.sys:%gc))
              (setq value 30d0) (kiln.sys:%gc))
            value)))
