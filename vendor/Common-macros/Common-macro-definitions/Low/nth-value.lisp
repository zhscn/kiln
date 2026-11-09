(cl:in-package #:common-macro-definitions)

;;; kiln: small constant indices read the value directly instead of
;;; consing a list.
(defmacro nth-value (n form)
  (cond ((eql n 0) `(values ,form))
        ((and (integerp n) (<= 1 n 8))
         (let ((vars (loop repeat (1+ n) collect (gensym "VAL"))))
           `(multiple-value-bind ,vars ,form
              (declare (ignore ,@(butlast vars)))
              ,(car (last vars)))))
        (t `(nth ,n (multiple-value-list ,form)))))
