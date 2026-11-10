;;; Macro environments retain each declaration's lexical binding and scope.
(eval '(macrolet ((declared-type (name &environment environment)
             (list 'quote (trucler:type
                           (trucler:describe-variable nil environment name)))))
  (let ((value 1))
    (declare (fixnum value))
    (format t "~S~%" (declared-type value))
    (let ((value "inner")) (format t "~S~%" (declared-type value)))
    (locally (declare (type (unsigned-byte 8) value))
      (format t "~S~%" (declared-type value))))
  (let ((value 1)) (format t "~S~%" (declared-type value)))))

(let ((function (compile nil '(lambda (value)
                              (declare (type (unsigned-byte 8) value))
                              (+ value 1)))))
  (print (funcall function 255))
  (print (handler-case (funcall function 256) (type-error () 'type-error))))
