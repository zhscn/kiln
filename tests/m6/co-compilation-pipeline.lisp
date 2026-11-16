(dolist (pipeline '(:mir))
  (let ((kiln.compiler::*compiler-pipeline* pipeline))
    (let ((function
            (compile nil
                     '(lambda ()
                        (macrolet ((observe ()
                                     (list 'quote
                                           (list kiln.compiler::*compiler-pipeline*
                                                 (kiln.compiler::compilation-request-pipeline
                                                  kiln.compiler::*compilation-request*)))))
                          (observe))))))
      (print (equal (funcall function) (list pipeline pipeline))))))

(dolist (pipeline '(:mir))
  (let ((kiln.compiler::*compiler-pipeline* pipeline))
    (let ((function
            (compile nil
                     '(lambda ()
                        (macrolet ((observe-nested ()
                                     (let* ((outer (list kiln.compiler::*compiler-pipeline*
                                                         (kiln.compiler::compilation-request-pipeline
                                                          kiln.compiler::*compilation-request*)))
                                            (nested
                                              (compile nil
                                                       '(lambda ()
                                                          (macrolet ((observe ()
                                                                       (list 'quote
                                                                             (list kiln.compiler::*compiler-pipeline*
                                                                                   (kiln.compiler::compilation-request-pipeline
                                                                                    kiln.compiler::*compilation-request*)))))
                                                            (observe))))))
                                       (list 'quote (list outer (funcall nested))))))
                          (observe-nested))))))
      (print (equal (funcall function) (list (list pipeline pipeline) (list pipeline pipeline)))))))
