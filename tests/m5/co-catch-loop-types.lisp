(let ((function
        (compile nil
                 '(lambda (limit)
                    (declare (fixnum limit))
                    (let ((counter 0) (cleanups 0))
                      (tagbody again
                         (catch 'tag
                           (if (>= counter limit) (go done))
                           (setq counter (1+ counter))
                           (unwind-protect (go again)
                             (setq cleanups (1+ cleanups))))
                       done)
                      (list counter cleanups))))))
  (print (funcall function 0))
  (print (funcall function 5)))

(let ((function
        (compile nil
                 '(lambda ()
                    (let ((value 0))
                      (list (block done
                              (catch 'tag
                                (unwind-protect
                                     (return-from done (progn (setq value 3) value))
                                  (setq value "cleanup"))))
                            value))))))
  (print (funcall function)))

(defun catch-loop-throw (tag)
  (throw tag :caught))

(let ((function
        (compile nil
                 '(lambda ()
                    (let ((value 0))
                      (block done
                        (let ((result (catch 'tag
                                        (setq value "changed")
                                        (catch-loop-throw 'tag))))
                          (list result value (length value)))))))))
  (print (funcall function)))

(let ((function
        (compile nil
                 '(lambda ()
                    (let ((value 0))
                      (tagbody
                         (catch 'tag
                           (unwind-protect (throw 'tag nil)
                             (setq value 42)
                             (go done)))
                         (setq value "unreachable")
                       done)
                      value)))))
  (print (funcall function)))
