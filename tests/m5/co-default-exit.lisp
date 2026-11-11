(print (block done (flet ((done (&optional (x (return-from done 17))) x)) (done) :bad)))
(print (block done (labels ((done (&key (x (return-from done 19))) x)) (done) :bad)))
(print (block done (flet ((done (&aux (x (return-from done 23))) x)) (done) :bad)))
(print (block done
         (flet ((done (&aux (x (return-from done 29))) x))
           (declare (notinline done)) (done) :bad)))
(print (block done
         (flet ((done (&aux (x 1)) (return-from done :body)))
           (declare (notinline done)) (list (done) :caller))))
(print (multiple-value-list
        (block done
          (flet ((done (&optional (x (return-from done (values 1 2)))) x)) (done) :bad))))
(print (block done
         (flet ((done (&optional (x (unwind-protect (return-from done :default)
                                     (return-from done :cleanup)))) x))
           (done) :bad)))
(let ((s :outer))
  (declare (special s))
  (print (list (block done
                 (flet ((done (s &optional (x (return-from done s))) (declare (special s)) x))
                   (done :parameter) :bad)) s)))
(let ((s :outer))
  (declare (special s))
  (print (list (block done
                 (flet ((done (&aux (s :aux) (x (return-from done s))) (declare (special s)) x))
                   (declare (notinline done)) (done) :bad)) s)))
(let ((function (compile nil '(lambda (flag)
                               (block done
                                 (flet ((done (&optional (x (return-from done :default)))
                                          (return-from done :body)))
                                   (if flag (done) (done :provided)) :caller))))))
  (print (funcall function t)) (print (funcall function nil)))
