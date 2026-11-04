(cl:in-package #:common-boot-hir-evaluator)

(defmethod ensure-thunk
    (client
     (instruction hir:enclose-instruction)
     lexical-environment)
  (let ((entry-point nil)
        (parse-arguments-instruction
          (hir:parse-arguments-instruction instruction)))
    (add-to-process
     (lambda ()
       (setf entry-point
             (parse-arguments-instruction-to-host-function
              client parse-arguments-instruction))))
    (make-thunk (client instruction lexical-environment
                 :inputs 0 :outputs 1)
      (setf (output 0)
            (enclose entry-point parse-arguments-instruction))
      (successor 0))))
