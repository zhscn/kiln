;;; The pretty printer (Inravina): PPRINT-LOGICAL-BLOCK, conditional
;;; newlines, the standard dispatch table, and FORMAT's pretty printing
;;; directives.

(defun show (string)
  (write-string string)
  (terpri))

(defun pp (object &optional (width 40))
  (let ((*print-pretty* t) (*print-right-margin* width))
    (show (write-to-string object))))

;;; Lists fill the line, then break.
(pp '(alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi))

;;; Code is laid out by the standard dispatch table.
(pp '(defun fact (n) (if (zerop n) 1 (* n (fact (- n 1))))))
(pp '(let ((a 1) (b 2) (c 3)) (print a) (print b) (print c)) 30)
(pp '(cond ((null x) nil) ((consp x) (car x)) (t (error "no ~a" x))) 30)
(pp ''quoted)
(pp '#'car)
(pp '`(a ,b ,@c))

;;; PPRINT-LOGICAL-BLOCK with a user function.
(defun pprint-pairs (stream list)
  (pprint-logical-block (stream list :prefix "{" :suffix "}")
    (loop (pprint-exit-if-list-exhausted)
          (write (pprint-pop) :stream stream)
          (write-string " => " stream)
          (write (pprint-pop) :stream stream)
          (pprint-exit-if-list-exhausted)
          (write-string ", " stream)
          (pprint-newline :linear stream))))

(let ((*print-pretty* t) (*print-right-margin* 80))
  (pprint-pairs *standard-output* '(:a 1 :b 2 :c 3))
  (terpri))
(let ((*print-pretty* t) (*print-right-margin* 15))
  (pprint-pairs *standard-output* '(:a 1 :b 2 :c 3))
  (terpri))

;;; *PRINT-LENGTH* and *PRINT-LEVEL* inside logical blocks.
(let ((*print-length* 3))
  (pp '(1 2 3 4 5 6)))
(let ((*print-level* 2))
  (pp '(1 (2 (3 (4))))))

;;; SET-PPRINT-DISPATCH on a copy of the table.
(let ((*print-pprint-dispatch* (copy-pprint-dispatch)))
  (set-pprint-dispatch 'integer (lambda (stream n) (write-string "#" stream) (write-string (let ((*print-pretty* nil)) (princ-to-string n)) stream)))
  (pp '(1 2 three)))
(pp '(1 2 three))

;;; FORMAT's logical blocks, conditional newlines, ~I and ~:T.
(show (format nil "~<~a~^ ~a~^ ~a~:>" '(x y z)))
(let ((*print-right-margin* 20))
  (show (format nil "~<(~;~@{~a~^ ~_~}~;)~:>" '(aaaaa bbbbb ccccc ddddd eeeee))))
(let ((*print-right-margin* 20))
  (show (format nil "~:<~@{~a~^ ~:_~}~:>" '(aaaaa bbbbb ccccc ddddd eeeee))))
(let ((*print-right-margin* 20))
  (show (format nil "~<~@{~a~^ ~:@_~}~:>" '(one two))))
(let ((*print-right-margin* 30))
  (show (format nil "~:<~w~^ ~:I~@_~@{~w~^ ~_~}~:>" '(foo bar baz qux quux))))
(show (format nil "~@<~@{~a~^, ~}~:@>" 'a 'b 'c))
(show (format nil "~:@<~a ~a~:@>" 'a 'b))

;;; PPRINT and PRIN1 with *PRINT-PRETTY*.
(pprint '(a b c))
(terpri)
(let ((*print-pretty* nil))
  (show (prin1-to-string '(defun f (x) x))))
(pp (make-array 3 :initial-contents '(1 2 3)))

;;; Khazern's error reports use the pretty printer.
(handler-case (macroexpand-1 '(loop for x in '(1 2) collect))
  (error (condition)
    (print (type-of condition)) (terpri) (show (substitute #\Space #\Newline (princ-to-string condition)))))
