(defun spread-ends (&rest arguments)
  (list (length arguments) (car arguments) (car (last arguments))))

(print (apply #'spread-ends nil))
(print (apply #'spread-ends 10 20 '(30 40)))
(print (apply #'spread-ends
              (loop for index below call-arguments-limit collect index)))

(handler-case (apply #'spread-ends (make-list (1+ call-arguments-limit)))
  (program-error () (print 'too-many)))
(handler-case (apply #'spread-ends '(1 . 9))
  (type-error (condition) (print (list 'bad-tail (type-error-datum condition)))))
(let ((cycle (list 1)))
  (setf (cdr cycle) cycle)
  (handler-case (apply #'spread-ends cycle)
    (program-error () (print 'bounded-cycle))))

(let ((objects (loop repeat 5 collect (list 'object))))
  (multiple-value-bind (first last)
      (apply (lambda (a b c d e)
               (declare (ignore b c d))
               (kiln.sys:%gc)
               (values a e))
             objects)
    (print (list (eq first (first objects)) (eq last (fifth objects))))))

(let ((order nil))
  (flet ((note (value) (push value order) value))
    (print (apply (lambda (&rest arguments) arguments)
                  (note 1) (note 2) (list (note 3) (note 4)))))
  (print (reverse order)))

(print (multiple-value-list
        (catch 'done
          (unwind-protect
               (apply (lambda (tag) (throw tag (values 7 8))) '(done))
            (kiln.sys:%gc)))))
