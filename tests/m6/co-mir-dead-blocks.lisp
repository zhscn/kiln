(defvar *dead-block-special* :outside)

(defun mir-dead-block-check (body expected)
  (dolist (pipeline '(:mir))
    (let* ((kiln.compiler::*compiler-pipeline* pipeline)
           (function (compile nil `(lambda (x) (declare (optimize (speed 3) (safety 1) (debug 1))) ,body))))
      (print (equal (funcall function 10) expected)))))

(mir-dead-block-check
 '(block out
    (flet ((f (a &optional (b x) (c x)) (return-from out -7)))
      (f 1 2 3) (multiple-value-call #'f (values 1 2))))
 -7)

(mir-dead-block-check
 '(flet ((target (a) (+ x a)))
    (if t (target 1) (flet ((consumer () (target 2))) (consumer))))
 11)

(mir-dead-block-check
 '(if nil
      (flet ((target (a) (+ x a)))
        (flet ((consumer () (multiple-value-call #'target (values 1)))) (consumer)))
      0)
 0)

(mir-dead-block-check
 '(progn
    (if nil (let ((*dead-block-special* 1)) *dead-block-special*) 0)
    (let ((*dead-block-special* (list x)))
      (catch 'done
        (unwind-protect (throw 'done *dead-block-special*) (kiln.sys:%gc)))))
 '(10))
(print (eq *dead-block-special* :outside))
