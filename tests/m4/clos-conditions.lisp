;;; The condition system: Predicament on CLOS.

(define-condition my-error (error)
  ((code :initarg :code :reader my-code)))

(define-condition my-warning (warning) ())

(print (handler-case (error "boom ~a" 1)
         (error (c)
           (list 'caught (class-name (class-of c))
                 (apply #'format nil (simple-condition-format-control c)
                        (simple-condition-format-arguments c))
                 (simple-condition-format-arguments c)))))
(print (handler-case (error 'my-error :code 42)
         (my-error (c) (my-code c))))
(print (handler-case (signal 'my-error :code 3)
         (error (c) (list 'signal (my-code c)))))
(print (signal "nobody handles this"))
(print (restart-case (progn (invoke-restart 'my-restart 5) 'not-here)
         (my-restart (x) (list 'restarted x))))
(handler-bind ((warning (lambda (c) (print 'warned) (muffle-warning c))))
  (warn 'my-warning)
  (print 'after-warn))
(print (ignore-errors (error "x") 'not-here))
(print (with-simple-restart (skip "Skip it.") (invoke-restart 'skip) 'not-here))
(print (typep (make-condition 'my-error :code 1) 'error))
(print (typep (make-condition 'my-error :code 1) 'warning))
(print (handler-case (error 'type-error :datum 1 :expected-type 'string)
         (type-error (c) (list (type-error-datum c) (type-error-expected-type c)))))
(print (block b
         (handler-bind ((error (lambda (c)
                                 (return-from b (list 'nonlocal (my-code c))))))
           (unwind-protect (error 'my-error :code 7)
             (print 'cleanup)))))
(print (handler-case (handler-case (error 'my-error :code 8)
                       (type-error () 'wrong))
         (my-error (c) (list 'outer (my-code c)))))
;; The inner HANDLER-CASE is the most recent handler: it transfers control
;; before the outer handler runs.
(print (let ((n 0))
         (handler-bind ((my-error (lambda (c) (declare (ignore c)) (incf n))))
           (handler-case (error 'my-error :code 9)
             (error () (list 'handled-after n))))))

;;; Conditions signaled by CLOS itself, defined early and made classes.
(defgeneric frob (x))
(print (handler-case (frob 1)
         (error (c) (class-name (class-of c)))))
(print (mapcar #'class-name
               (clostrophilia:class-precedence-list
                (find-class 'clostrophilia:no-applicable-method-error))))

;;; Errors detected by compiled code and the runtime.
(print (handler-case (car 5)
         (type-error (c) (list (type-error-datum c) (type-error-expected-type c)))))
(print (handler-case (no-such-function 1)
         (undefined-function (c) (cell-error-name c))))
(print (handler-case (/ 1 0) (division-by-zero () 'division-by-zero)))
(print (handler-case (floor 7 0) (arithmetic-error () 'arithmetic-error)))
(print (handler-case (funcall (lambda (x) x)) (program-error () 'wrong-argument-count)))
(print (handler-case (symbol-value (gensym)) (unbound-variable () 'unbound)))
(print (handler-case (svref (vector 1 2) 5) (error () 'bad-index)))
(print (handler-case (+ 1 'a) (type-error (c) (type-error-datum c))))
(print (handler-case (funcall 'no-such-function-either) (cell-error () 'cell-error)))
