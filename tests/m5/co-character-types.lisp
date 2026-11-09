(declaim (notinline character))
(setf *print-pretty* nil)

(defun character-type-results (object)
  (list (typep object 'standard-char)
        (typep object 'base-char)
        (typep object 'extended-char)
        (typep object '(and character extended-char))))
(print (mapcar #'character-type-results
               (mapcar #'code-char '(0 9 10 31 32 126 127 128 255 256 1000))))
(print (mapcar #'character-type-results (list 1 nil "a")))
(print (loop repeat 3 always
             (equal (mapcar #'character-type-results
                            (mapcar #'code-char '(128 10 0 1000 32)))
                    '((nil nil t t) (t t nil nil) (nil t nil nil)
                      (nil nil t t) (t t nil nil)))))
(print (mapcar #'character (list #\a "b" 'c :d (make-symbol "e"))))
(let* ((storage (make-array 4 :element-type 'character :initial-contents "abcd"))
       (displaced (make-array 2 :element-type 'character :displaced-to storage
                              :displaced-index-offset 1 :fill-pointer 1)))
  (print (char= (character displaced) #\b)))
(print (every (lambda (object)
                (handler-case (progn (character object) nil)
                  (type-error (condition)
                    (and (eq object (type-error-datum condition))
                         (typep condition 'simple-type-error)))))
              (list nil 1 "" "ab" 'ab (make-symbol ""))))
(defun check-character-eval ()
  (print (eval '(let ((characters (mapcar #'code-char '(0 10 65 128 1000))))
                 (loop for c in characters collect
                       (list (typecase c (standard-char :standard)
                                         (base-char :base) (extended-char :extended))
                             (etypecase c (base-char :base) (extended-char :extended))))))))
(check-character-eval)
#+kiln
(let ((kiln.kernel::*eval-function* nil) (kiln.kernel::*compile-function* nil))
  (check-character-eval))
#-kiln
(check-character-eval)
