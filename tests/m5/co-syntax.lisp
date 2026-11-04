;;; s-expression-syntax on kiln (docs/11 §3, M5.2): special forms and
;;; macro forms parsed with the list builder. Objects other than lists,
;;; symbols, numbers and strings are shown as their class names.

(defun show (tree)
  (cond ((consp tree) (cons (show (car tree)) (show (cdr tree))))
        ((typep tree 'standard-object) (list :object (class-name (class-of tree))))
        (t tree)))

(defun parse-form (form)
  (let ((ses (find-package "S-EXPRESSION-SYNTAX")))
    (show (funcall (find-symbol "PARSE" ses) 'list
                   (funcall (find-symbol "FIND-SYNTAX" ses) (first form))
                   form))))

(dolist (form '((let ((x 1)) (+ x 2))
                (if a b)
                (flet ((f (x &optional (y 2)) (list x y))) (f 1))
                (defun f (a &key (b 1 bp)) (declare (ignore bp)) a)
                (destructuring-bind (a (b . c) &rest d) x (list a b c d))))
  (let ((*print-pretty* nil))
    (format t "~S~%" (parse-form form))))

;;; A syntax error.
(handler-case (parse-form '(let (1) x))
  (error (c) (format t "error: ~A~%" (type-of c))))
