(in-package #:cl-user)

;;; Dispatch closures belong to individual readtables. Merge compares their
;;; subcharacter handlers, while ordinary macro handlers must still agree.
(let ((left (copy-readtable nil))
      (right (copy-readtable nil)))
  (named-readtables:merge-readtables-into left right)
  (make-dispatch-macro-character #\! nil left)
  (make-dispatch-macro-character #\! nil right)
  (set-dispatch-macro-character #\! #\a #'list left)
  (set-dispatch-macro-character #\! #\a #'list right)
  (named-readtables:merge-readtables-into left right)
  (assert (eq (get-dispatch-macro-character #\! #\a left) #'list))
  (set-dispatch-macro-character #\! #\a #'vector right)
  (assert (handler-case
              (progn (named-readtables:merge-readtables-into left right) nil)
            (named-readtables:reader-macro-conflict () t)))
  (set-dispatch-macro-character #\! #\a #'list right)
  (set-macro-character #\? #'list nil left)
  (set-macro-character #\? #'vector nil right)
  (assert (handler-case
              (progn (named-readtables:merge-readtables-into left right) nil)
            (named-readtables:reader-macro-conflict () t))))

#+kiln
(let ((evaluations 0))
  (assert (eq :body (fset::with-lock ((progn (incf evaluations)
                                          (fset::make-lock "regression"))
                                    :wait? (progn (incf evaluations) nil))
                     :body)))
  (assert (= evaluations 2)))

(assert (= (fset:size (fset:set 1 2 2)) 2))

(assert (char= (fset::make-char 42 2) (code-char 554)))
(let ((characters (list #\A (code-char 554) #\B)))
  (assert (equal characters (fset:convert 'list (fset:convert 'fset:seq characters)))))
