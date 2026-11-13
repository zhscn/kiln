(print (multiple-value-list (values-list nil)))
(print (multiple-value-list (values-list '(nil))))
(print (multiple-value-list (values-list '(1 2 3))))

(let ((values (loop for index below multiple-values-limit collect index)))
  (multiple-value-call
      (lambda (&rest received)
        (kiln.sys:%gc)
        (print (list (length received) (first received) (car (last received)))))
    (values-list values)))

(handler-case (values-list (make-list (1+ multiple-values-limit)))
  (program-error () (print 'too-many)))
(handler-case (values-list '(1 . 9))
  (type-error (condition) (print (list 'bad-tail (type-error-datum condition)))))
(let ((cycle (list 1)))
  (setf (cdr cycle) cycle)
  (handler-case (values-list cycle)
    (program-error () (print 'bounded-cycle))))

(print
 (catch 'done
   (unwind-protect
        (handler-case (values-list '(1 . 9))
          (type-error () (throw 'done 'caught)))
     (kiln.sys:%gc))))
