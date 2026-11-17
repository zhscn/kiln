(defun backend-test-error (result operation)
  (handler-case (kiln.lir:require-init result operation)
    (kiln.lir:backend-error (condition) condition)))

(format t "~S~%" (kiln.lir:backend-error-stage
  (backend-test-error (kiln.sys:%primop :compile-packet #(1 2) #()) :compile-packet)))
(format t "~S~%" (kiln.lir:backend-error-stage
  (backend-test-error (kiln.sys:%primop :compile-program '(:module "legacy") #()
                                       (kiln.lir:target-fingerprint)) :compile-program)))
(format t "~S~%" (kiln.lir:backend-error-stage
  (backend-test-error (kiln.sys:%primop :compile-program '(:lir-module "bad") #() 0) :compile-program)))
(let ((packet (kiln.lir:encode-program '(:lir-module "bad"))))
  (format t "~S~%" (kiln.lir:backend-error-stage
    (backend-test-error (kiln.sys:%primop :compile-packet packet #()) :compile-packet))))
(format t "~S~%" (kiln.lir:backend-error-stage
  (backend-test-error
    (kiln.sys:%primop :compile-program
      '(:lir-module "binding" (:init "entry") (:literals 1)
        (:function "entry" (:block e (:return ())))) #() (kiln.lir:target-fingerprint))
    :compile-program)))
(let* ((program '(:lir-module "unicode" (:init "entry")
                   (:function "entry" (:block e (:unknown-λ)))))
       (condition (backend-test-error
                    (kiln.sys:%primop :compile-program program #() (kiln.lir:target-fingerprint)) :compile-program)))
  (format t "~S~%" (not (null (search "λ" (kiln.lir:backend-error-message condition))))))
(let* ((name (make-symbol (make-string 17000 :initial-element #\x)))
       (program (list :lir-module "bounded" '(:init "entry")
                      (list :function "entry" (list :block 'e (list name))))))
  (dotimes (index 128)
    (let ((condition (backend-test-error
                      (kiln.sys:%primop :compile-program program #() (kiln.lir:target-fingerprint)) :compile-program)))
      (unless (and (kiln.lir:backend-error-truncated-p condition)
                   (<= (length (kiln.lir:backend-error-message condition)) 16384))
        (error "Invalid bounded backend diagnostic."))))
  (format t "~S~%" t))
(format t "~S~%" (funcall (compile nil '(lambda (x) (+ x 1))) 8))
