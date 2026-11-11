(defun double-join (key value)
  (declare (double-float value))
  (* (case key
       (0 (1+ value)) (1 (1- value)) (2 (abs value)) (t (- value)))
     2d0))
(dolist (key '(0 1 2 3)) (print (double-join key -3d0)))

(let ((function
        (compile nil
                 '(lambda (flag value)
                    (declare (double-float value))
                    (let ((log nil))
                      (list
                       (* (if (progn (push :test log) flag)
                              (progn (push :yes log) (1+ value))
                              (progn (push :no log) (1- value)))
                          (progn (push :right log) (kiln.sys:%gc) 2d0))
                       (reverse log)))))))
  (print (funcall function t 3d0))
  (print (funcall function nil 3d0)))

(let ((value 3d0))
  (declare (double-float value))
  (print (* (multiple-value-prog1
                (if (plusp value) (1+ value) (1- value))
              (setq value 10d0) (kiln.sys:%gc))
            value)))

(print (* (let ((temporary 3d0))
            (declare (double-float temporary))
            (setq temporary (if (plusp temporary) (1+ temporary) (1- temporary)))
            (kiln.sys:%gc)
            (1- temporary))
          2d0))

(let ((function (compile nil '(lambda (flag)
                               (if flag (values 1d0 :yes) (values 2d0 :no))))))
  (print (multiple-value-list (funcall function t)))
  (print (multiple-value-list (funcall function nil))))

(print (* (multiple-value-prog1
              (if (identity t) (values 3d0 :discarded) (values 4d0 :unused))
            (kiln.sys:%gc))
          2d0))

(let ((value 3d0))
  (declare (double-float value))
  (let ((first (if (identity t) (1+ value) (1- value)))
        (second (progn (setq value 10d0) (kiln.sys:%gc) 1d0)))
    (declare (double-float first second))
    (print (list first second value))))

(print (block done
         (* (if (identity t) (return-from done 17d0) (+ 3d0 4d0)) 2d0)))

(print (handler-case
           (let ((value (if (identity t) "bad" 3d0)))
             (declare (double-float value)) value)
         (type-error () 'type-error)))
