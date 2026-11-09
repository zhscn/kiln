(let* ((home (make-package "APROPOS-HOME" :use nil))
       (user (make-package "APROPOS-USER" :use nil))
       (external (intern "UNIQUE-APROPOS-EXTERNAL" home))
       (internal (intern "UNIQUE-APROPOS-INTERNAL" home)))
  (unwind-protect
       (progn
         (export external home)
         (use-package home user)
         (import internal user)
         (print (equal (apropos-list "unique-apropos" user)
                       (list external internal)))
         (print (equal (apropos-list "unique-apropos" home t) (list external)))
         (print (null (apropos-list "unique-apropos" user t)))
         (print (equal (apropos-list "unique-apropos" nil t) (list external)))
         (print (= (length (apropos-list "unique-apropos")) 2))
         (let ((query (make-array 31 :element-type 'character
                                 :initial-contents "unique-apropos-external-ignored"
                                 :fill-pointer 22)))
           (print (equal (apropos-list query home) (list external))))
         (let ((output (with-output-to-string (*standard-output*)
                         (assert (null (multiple-value-list
                                        (apropos "unique-apropos" home)))))))
           (print (and (search "UNIQUE-APROPOS-EXTERNAL" output)
                       (search "UNIQUE-APROPOS-INTERNAL" output) t))))
    (delete-package user)
    (delete-package home)))
