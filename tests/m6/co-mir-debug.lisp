(assert (= 1 (svref kiln.kernel::*optimization-qualities* 2)))
(loop for quality in '(:speed :safety :debug :space :compilation-speed)
      for level across kiln.kernel::*optimization-qualities*
      do (assert (= level (kiln.compiler::hir-policy-quality nil quality))))

(defun mir-debug-compile (name form)
  (destructuring-bind (operator parameters &rest body) form
    (compile name (list* operator parameters '(declare (optimize (debug 3))) body))))

(defun mir-debug-vars-for (name)
  (let ((frame (find name (kiln.sys:frame-list) :key #'kiln.sys:frame-name :test #'equal)))
    (kiln.sys:%gc)
    (when frame (kiln.sys:frame-variables frame))))

(let ((function
        (mir-debug-compile
         'mir-debug-values
         '(lambda (x)
            (let ((y (+ x 1)))
              (let ((vars (mir-debug-vars-for 'mir-debug-values)))
                (list (cdr (assoc 'x vars)) (cdr (assoc 'y vars)) (+ x y))))))))
  (print (equal (funcall function 10) '(10 11 21))))

(let ((function
        (mir-debug-compile
         'mir-debug-assignment
         '(lambda (x)
            (let ((old x))
              (setq x (+ x 2))
              (let ((vars (mir-debug-vars-for 'mir-debug-assignment)))
                (list (cdr (assoc 'x vars)) (cdr (assoc 'old vars))
                      (count 'x vars :key #'car) x old)))))))
  (print (equal (funcall function 10) '(12 10 1 12 10))))

(let ((function
        (mir-debug-compile
         'mir-debug-shadow
         '(lambda (x)
            (let ((x (+ x 1)))
              (let ((vars (mir-debug-vars-for 'mir-debug-shadow)))
                (list (cdr (assoc 'x vars)) x)))))))
  (print (equal (funcall function 10) '(11 11))))

(let ((function
        (mir-debug-compile
         'mir-debug-cell
         '(lambda (n)
            (let ((count n))
              (flet ((bump () (incf count)))
                (bump)
                (let ((vars (mir-debug-vars-for 'mir-debug-cell)))
                  (bump)
                  (list (cdr (assoc 'count vars)) count))))))))
  (print (equal (funcall function 5) '(6 7))))

(let ((function
        (mir-debug-compile
         'mir-debug-optional
         '(lambda (x &optional (y (+ x 1) yp) &rest tail)
            (let ((vars (mir-debug-vars-for 'mir-debug-optional)))
              (equal (list (cdr (assoc 'x vars)) (cdr (assoc 'y vars))
                           (cdr (assoc 'yp vars)) (cdr (assoc 'tail vars)))
                     (list x y yp tail)))))))
  (print (funcall function 3))
  (print (funcall function 3 9 :a :b)))

(let ((function
        (mir-debug-compile
         'mir-debug-keywords
         '(lambda (&key (x 4 xp) (y (+ x 1)))
            (let ((vars (mir-debug-vars-for 'mir-debug-keywords)))
              (equal (list (cdr (assoc 'x vars)) (cdr (assoc 'xp vars)) (cdr (assoc 'y vars)))
                     (list x xp y)))))))
  (print (funcall function))
  (print (funcall function :x 9)))

(let ((function
        (mir-debug-compile
         'mir-debug-double
         '(lambda (x)
            (declare (type double-float x))
            (let ((y (+ x 1.0d0)))
              (let ((vars (mir-debug-vars-for 'mir-debug-double)))
                (list (cdr (assoc 'x vars)) (cdr (assoc 'y vars)) (+ x y))))))))
  (print (equal (funcall function 1.25d0) '(1.25d0 2.25d0 3.5d0))))

(let* ((maker
         (mir-debug-compile
          'mir-debug-maker
          '(lambda (x)
             (lambda (y)
               (let ((vars (mir-debug-vars-for '(lambda :in mir-debug-maker))))
                 (list (eq (cdr (assoc 'x vars)) x) (cdr (assoc 'y vars)) (car x) y))))))
       (function (funcall maker (list :token))))
  (print (equal (funcall function 3) '(t 3 :token 3))))

(let* ((session (kiln.compiler:make-session))
       (forms '((defun mir-debug-file-cell (x y)
                  (declare (optimize (debug 3)))
                  (incf x)
                  (values x y))))
       (module (kiln.compiler:compile-module
                (kiln.compiler::front-end-forms forms session) "mir-debug-file" :session session))
       (program (kiln.lir:module-program module)))
  (assert (loop for function in (cddr program)
                thereis (and (eq (first function) :function)
                             (some (lambda (variable) (eq (third variable) :cell))
                                   (sixth (assoc :debug (cddr function))))))))
