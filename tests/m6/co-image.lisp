;;;; A heap image with the compiler module: COMPILE makes native
;;;; code in the process started from the image, and an image saved after
;;;; that holds the code (co-image.image2).

(defvar *sum*)

(defun main ()
  (format t "native ~a~%" (not (null kiln.kernel::*compile-function*)))
  (setf *sum* (compile nil '(lambda (n) (let ((s 0)) (dotimes (i n s) (incf s i))))))
  (format t "sum ~a~%" (funcall *sum* 1000))
  (compile 'later '(lambda (x) (handler-case (* x (car x)) (type-error () (list :oops x)))))
  (format t "later ~a~%" (later 21))
  (format t "eval ~a~%" (eval '(let ((x 5)) (+ x 1))))
  (kiln.sys:save-image "co-image-2.img" :toplevel #'main-2))

(defun main-2 ()
  (format t "second image~%")
  (format t "sum ~a later ~a~%" (funcall *sum* 10) (later 2))
  (dotimes (i 20000) (make-list 50))
  (kiln.sys:%gc)
  (compile 'again '(lambda () (+ (funcall *sum* 4) (length (later 3)))))
  (format t "again ~a~%" (again)))

(kiln.sys:save-image "co-image.img" :toplevel #'main)
(format t "saved~%")
