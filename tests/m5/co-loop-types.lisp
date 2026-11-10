(let ((function
        (compile nil '(lambda (limit)
                        (declare (fixnum limit))
                        (let ((counter 0))
                          (tagbody top
                             (if (>= counter limit) (go done))
                             (setq counter (1+ counter))
                             (go top)
                           done)
                          counter)))))
  (print (funcall function 0))
  (print (funcall function 5))
  (print (handler-case (funcall function "bad") (type-error () 'type-error))))

(let ((function
        (compile nil '(lambda ()
                        (block done
                          (let ((value 1))
                            (tagbody
                               (unwind-protect (go use) (setq value "changed"))
                             use
                               (return-from done value))))))))
  (print (funcall function)))
