;;;; A heap image with the compiler module (docs/15): COMPILE makes native
;;;; code in the process started from the image.

(defun main ()
  (format t "native ~a~%" (not (null kiln.kernel::*compile-function*)))
  (let ((f (compile nil '(lambda (n) (let ((s 0)) (dotimes (i n s) (incf s i)))))))
    (format t "sum ~a~%" (funcall f 1000)))
  (compile 'later '(lambda (x) (* x 2)))
  (format t "later ~a~%" (later 21))
  (format t "eval ~a~%" (eval '(let ((x 5)) (+ x 1))))
  (format t "after compile: ~a~%"
          (handler-case (progn (kiln.sys:save-image "co-image-x.img") :saved)
            (error () :refused))))

(kiln.sys:save-image "co-image.img" :toplevel #'main)
(format t "saved~%")
