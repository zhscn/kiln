(print (equal (macrolet ((capture (&whole form argument) `(list ',form ,argument)))
                (capture 7))
              '((capture 7) 7)))
(print (equal (macrolet ((capture (&whole form first &rest tail)
                          (declare (ignore first))
                          `'(,tail ,form)))
                (capture a b c))
              '((b c) (capture a b c))))
(print (eq (macrolet ((nil () '':nil-name)) (nil)) :nil-name))

(dolist (evaluator (list #'eval #+kiln #'kiln.kernel::interpreted-eval #-kiln #'eval))
  (print (equal (funcall evaluator
                        '(macrolet ((capture (&whole form argument) `(list ',form ,argument)))
                           (capture 7)))
                '((capture 7) 7)))
  (print (eq (funcall evaluator '(macrolet ((nil () '':nil-name)) (nil))) :nil-name))
  (print (handler-case
             (progn (funcall evaluator '(macrolet ((no-arguments () :unused))
                                         (no-arguments 1)))
                    nil)
           (program-error () t))))

(print (handler-case
           (progn (eval '(defmethod local-macro-next-method ((object t))
                           (next-method-p nil)))
                  (funcall 'local-macro-next-method nil)
                  nil)
         (program-error () t)))
