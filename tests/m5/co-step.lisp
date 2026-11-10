#+kiln
(defun run-step-probe (form mode nativep)
  (let ((events nil) (finished 0)
        (kiln.kernel::*compile-function* (and nativep kiln.kernel::*compile-function*))
        (kiln.kernel::*eval-function* (and nativep kiln.kernel::*eval-function*)))
    (let ((kiln.sys:*stepper-hook*
            (lambda (condition)
              (push (car (kiln.sys:step-form condition)) events)
              (invoke-restart mode))))
      (handler-bind ((kiln.sys:step-finished-condition
                       (lambda (condition) (declare (ignore condition)) (incf finished))))
        (let ((result (multiple-value-list (eval form))))
          (list result (reverse events) finished))))))
#+kiln
(dolist (nativep '(nil t))
  (print (run-step-probe '(step (+ 1 (* 2 3))) 'kiln.sys:step-into nativep))
  (print (run-step-probe '(step (progn (+ 1 (* 2 3)) (- 7 2)))
                         'kiln.sys:step-next nativep))
  (print (run-step-probe '(step (progn (+ 1 (* 2 3)) (- 7 2)))
                         'kiln.sys:step-continue nativep))
  (print (run-step-probe '(step (values 1 2 3)) 'kiln.sys:step-next nativep))
  (print (run-step-probe '(step (values)) 'kiln.sys:step-next nativep))
  (print (first (run-step-probe
                 '(let ((x 17)) (step (let ((y 3)) (values (+ x y) x y))))
                 'kiln.sys:step-into nativep)))
  (print (first (run-step-probe
                 '(block done (step (unwind-protect (return-from done 42) (values))))
                 'kiln.sys:step-into nativep)))
  (print (first (run-step-probe
                 '(catch 'done (step (throw 'done (values 42 43))))
                 'kiln.sys:step-into nativep)))
  (print (first (run-step-probe
                 '(step (flet ((twice (x) (+ x x))) (twice 21)))
                 'kiln.sys:step-into nativep)))
  (print (first (run-step-probe
                 '(step (macrolet ((twice (x) `(+ ,x ,x))) (twice 21)))
                 'kiln.sys:step-into nativep)))
  (print (run-step-probe
          '(step (progn (step (+ 1 (* 2 3))) (- 7 2)))
          'kiln.sys:step-continue nativep)))
#-kiln
(dotimes (i 2)
  (declare (ignore i))
  (mapc #'print '(((7) (* +) 1) ((5) (* + -) 1) ((5) (*) 1)
                 ((1 2 3) (values) 1) (nil (values) 1)
                 (20 17 3) (42) (42 43) (42) (42) ((5) (* -) 2))))
#+kiln
(let* ((input (make-string-input-stream "N N"))
       (output (make-string-output-stream))
       (*query-io* (make-two-way-stream input output)))
  (print (step (+ 1 (* 2 3))))
  (print (not (null (search "Step:" (get-output-stream-string output))))))
#-kiln (progn (print 7) (print t))
#+kiln (print (list kiln.kernel::*step-enabled* kiln.kernel::*step-continued*))
#-kiln (print '(nil nil))

#+kiln
(let ((kiln.sys:*stepper-hook* nil))
  (print (step (macrolet ((twice (x) `(+ ,x ,x))) (twice 21)))))
#-kiln (print 42)
#+kiln
(let ((events nil) (kiln.sys:*stepper-hook* nil))
  (handler-bind ((kiln.sys:step-form-condition
                   (lambda (condition)
                     (push (car (kiln.sys:step-form condition)) events)
                     (invoke-restart 'kiln.sys:step-next))))
    (print (step (+ 1 (* 2 3)))))
  (print (reverse events)))
#-kiln (progn (print 7) (print '(* +)))
#+kiln
(let ((kiln.sys:*stepper-hook* nil))
  (print (handler-case (step (error "step probe")) (error () :caught))))
#-kiln (print :caught)
(defun step-reference-inner (x) (* x 2))
(defun step-reference-outer (x y) (+ x y))
(declaim (notinline step-reference-inner step-reference-outer))
(let ((events nil)
      (*trace-output* (make-string-output-stream)))
  #+kiln
  (let ((kiln.sys:*stepper-hook*
          (lambda (condition)
            (push (list (symbol-name (car (kiln.sys:step-form condition)))
                        (kiln.sys:step-args condition)) events)
            (invoke-restart 'kiln.sys:step-into))))
    (print (step (step-reference-outer 3 (step-reference-inner 3)))))
  #+sbcl
  (handler-bind ((sb-ext:step-form-condition
                   (lambda (condition)
                     (push (list (symbol-name (car (read-from-string
                                                    (sb-ext:step-condition-form condition))))
                                 (sb-ext:step-condition-args condition)) events)
                     (invoke-restart 'sb-ext:step-into))))
    (print (step (step-reference-outer 3 (step-reference-inner 3)))))
  (print (reverse events)))
#+kiln
(dolist (nativep '(nil t))
  (let ((events nil)
        (kiln.kernel::*compile-function* (and nativep kiln.kernel::*compile-function*))
        (kiln.kernel::*eval-function* (and nativep kiln.kernel::*eval-function*)))
    (let ((kiln.sys:*stepper-hook*
            (lambda (condition)
              (let ((name (car (kiln.sys:step-form condition))))
                (push name events)
                (invoke-restart (if (eq name '+) 'kiln.sys:step-out 'kiln.sys:step-into))))))
      (print (eval '(step (flet ((worker (x) (+ x 1) (* x 2)))
                           (list (worker 3) 17))))))
    (print (reverse events))))
#-kiln
(dotimes (i 2) (declare (ignore i)) (print '(6 17)) (print '(worker + list)))
