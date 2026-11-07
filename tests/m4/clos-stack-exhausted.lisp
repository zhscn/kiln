;;; Stack exhaustion signals a STORAGE-CONDITION (KILN.SYS:STACK-EXHAUSTED)
;;; instead of crashing; after the handler unwinds, the limit is raised
;;; again, so it can happen again; on a stack of %CALL-ON-NEW-STACK too.

(defun show (x) (write-line (prin1-to-string x)))

(defun deep (n) (if (= n 0) 0 (+ 1 (deep (- n 1)))))
(defun forever (n) (+ 1 (forever (+ n 1))))

(show (deep 10000))
(dotimes (i 3)
  (show (handler-case (forever 0)
          (storage-condition (c) (list 'caught (type-of c) (typep c 'error))))))
(show (handler-case (forever 0) (error () 'error) (serious-condition () 'serious)))
(show (deep 10000))
(show (kiln.sys:%call-on-new-stack
       (lambda (x) (handler-case (forever x) (storage-condition () 'caught-on-new-stack)))
       0))
(show (handler-case (kiln.sys:%call-on-new-stack #'forever 0)
        (storage-condition () 'caught-below-new-stack)))
(show (deep 10000))
