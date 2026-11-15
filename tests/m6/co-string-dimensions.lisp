(let ((string (make-array 3 :element-type 'base-char :initial-element #\x :fill-pointer 0)))
  (print (and (typep string '(string 3)) (typep string '(base-string 3))
              (not (typep string '(string 0))) (not (typep string '(base-string 0)))))
  (setf (fill-pointer string) 2)
  (print (and (typep string '(string 3)) (not (typep string '(string 2))))))

(let* ((backing (make-array 5 :element-type 'character :initial-element #\x))
       (string (make-array 3 :element-type 'character :displaced-to backing
                            :displaced-index-offset 1 :fill-pointer 1)))
  (print (and (typep string '(string 3)) (not (typep string '(string 1))))))

(dolist (pipeline '(:hir :mir))
  (let* ((kiln.compiler::*compiler-pipeline* pipeline)
         (function (compile nil '(lambda (string) (declare (optimize safety)) (the (string 1) string))))
         (string (make-array 1 :element-type 'base-char :initial-element #\x :fill-pointer 0)))
    (print (eq string (funcall function string)))))
