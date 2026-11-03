;; Multiple values.
(defun two () (values 1 2))
(defun none () (values))
(defun many () (values 1 2 3 4 5 6))

(print (multiple-value-list (two)))
(print (multiple-value-list (none)))
(print (multiple-value-list (many)))
(print (two))                         ; primary value only
(print (none))                        ; NIL
(print (multiple-value-call #'list (two) (none) (many) 7))

;; Values pass through PROGN, IF, LET, BLOCK, CATCH, function returns.
(defun pass (x)
  (if x
      (let ((y 1)) y (two))
      (block b (return-from b (values 'a 'b 'c)))))
(print (multiple-value-list (pass t)))
(print (multiple-value-list (pass nil)))
(print (multiple-value-list (catch 'k (two))))

;; ... and survive cleanups and MULTIPLE-VALUE-PROG1, which call functions
;; that return values of their own.
(defun noisy () (many) (values 'x 'y))
(print (multiple-value-list (unwind-protect (two) (noisy))))
(print (multiple-value-list (multiple-value-prog1 (many) (noisy) (%gc))))
(print (multiple-value-list
        (block b
          (unwind-protect (return-from b (values 7 8 9))
            (noisy)))))

;; Special bindings in between.
(defvar *s* 0)
(print (multiple-value-list (let ((*s* 1)) (two))))

;; MULTIPLE-VALUE-BIND, NTH-VALUE, VALUES-LIST, APPLY.
(multiple-value-bind (a b c) (two)
  (print (list a b c)))
(print (nth-value 1 (two)))
(print (multiple-value-list (values-list '(p q r))))
(print (apply #'list 1 2 '(3 4 5)))
(print (apply #'+ '(1 2)))
(defun sum5 (a b c d e) (+ a (+ b (+ c (+ d e)))))
(print (apply #'sum5 1 '(2 3 4 5)))
(print (multiple-value-call #'sum5 (two) (values 3 4 5)))

;; Many values through a list conversion under GC pressure.
(defun lots () (values (list 1) (list 2) (list 3) (list 4) (list 5) (list 6) (list 7) (list 8)))
(print (multiple-value-list (multiple-value-prog1 (lots) (%gc))))
