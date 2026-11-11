(defun double-block-result (flag value)
  (declare (double-float value))
  (* (block done (if flag (return-from done (1+ value)) (1- value))) 2d0))
(print (double-block-result t 3d0))
(print (double-block-result nil 3d0))

(let ((function
        (compile nil
                 '(lambda (value)
                    (declare (double-float value))
                    (* (block done
                         (unwind-protect (return-from done (1+ value))
                           (setq value 20d0) (kiln.sys:%gc)))
                       value)))))
  (print (funcall function 3d0)))

(let ((value 3d0))
  (declare (double-float value))
  (print (* (block done
              (unwind-protect (return-from done (1+ value))
                (kiln.sys:%gc)
                (return-from done (1- value)))) 2d0)))

(defun double-block-throw (tag) (throw tag :caught))
(let ((value 3d0))
  (declare (double-float value))
  (print (catch 'tag
           (* (block done
                (unwind-protect (progn (double-block-throw 'tag) (1+ value))
                  (kiln.sys:%gc)
                  (return-from done (1- value)))) 2d0))))

(let ((value 3d0))
  (declare (double-float value))
  (print (* (block outer
              (block inner (return-from outer (1+ value)))
              (1- value)) 2d0)))

(print (multiple-value-list
         (block done (return-from done (values 1d0 :full-values)))))

(let ((value 3d0))
  (declare (double-float value))
  (print (* (the double-float
              (block done
                (flet ((leave () (return-from done (1+ value))))
                  (declare (notinline leave))
                  (funcall (identity #'leave)))))
            2d0)))
