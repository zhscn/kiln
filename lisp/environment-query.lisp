(in-package #:kiln.compiler)

(defmacro with-environment-query ((result kind name &key (record-if t) (prepare t)) &body body)
  "Keep dependency preparation, lookup and fact recording in one operation."
  (let ((key-kind (gensym "KIND")) (key-name (gensym "NAME")))
    `(let ((,key-kind ,kind) (,key-name ,name))
       ,@(when prepare `((prepare-dependency ,key-kind ,key-name)))
       (let ((,result (progn ,@body)))
         (when ,record-if (record-dependency ,key-kind ,key-name))
         ,result))))

(defun global-function-query-p (description)
  (or (null description)
      (typep description '(or trucler:global-function-description trucler:global-macro-description))))
