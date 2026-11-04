;;; LOOP in the image (Khazern), the run-time macro environment and
;;; closer-mop.

;;; The expansion the host's Khazern produced at compile time.
(defmacro compile-time-expansion (form)
  `',(macroexpand-1 form))

;;; Are A and B the same tree, up to a consistent renaming of uninterned
;;; symbols?
(defun similar-expansions (a b)
  (let ((renaming '()))
    (labels ((walk (a b)
               (cond ((and (symbolp a) (symbolp b)
                           (null (symbol-package a)) (null (symbol-package b)))
                      (let ((entry (assoc a renaming)))
                        (if entry
                            (eq (cdr entry) b)
                            (progn (push (cons a b) renaming) t))))
                     ((and (consp a) (consp b))
                      (and (walk (car a) (car b)) (walk (cdr a) (cdr b))))
                     ((and (stringp a) (stringp b)) (string= a b))
                     (t (eql a b)))))
      (walk a b))))

(defmacro check-expansion (form)
  `(format t "~a ~s~%"
           (if (similar-expansions (macroexpand-1 ',form) (compile-time-expansion ,form)) "same" "DIFFERENT")
           ',form))

(format t "~s~%" (not (null (macro-function 'loop))))
(check-expansion (loop for i from 1 to 3 collect i))
(check-expansion (loop for x in '(1 2 3) and y = 0 then x sum (* x y)))
(check-expansion (loop for (a . b) on '(1 2 3) by #'cddr when (oddp a) collect a into odds finally (return odds)))
(check-expansion (loop for c across "abc" count (char= c #\b)))
(check-expansion (loop for k being the hash-keys of (make-hash-table) using (hash-value v) collect (cons k v)))
(check-expansion (loop with n = 0 repeat 3 do (incf n) maximize n))
(check-expansion (loop named outer for i below 10 thereis (and (> i 5) i)))
(check-expansion (loop (loop-finish)))
(check-expansion (loop for i downfrom 10 above 0 by 2 append (list i) into l
             finally (return (nreverse l))))

;;; Errors are Khazern's conditions; the list of expected clause names
;;; comes from the methods of PARSE-CLAUSE (through closer-mop). (Their
;;; reports need the pretty printer, docs/10 §19.)
(defun show-loop-error (c)
  (format t "error: ~a ~s~%" (type-of c) (khazern::expected-keywords c)))
(handler-case (macroexpand-1 '(loop for i from 1 frob 3))
  (error (c) (show-loop-error c)))
(handler-case (macroexpand-1 '(loop blah))
  (error (c) (show-loop-error c)))

;;; A macro of the program exists at run time too.
(defmacro twice-loop-test (form) `(progn ,form ,form))
(format t "~s~%" (macroexpand-1 '(twice-loop-test (f))))
(format t "~s~%" (macroexpand '(twice-loop-test (twice-loop-test x))))
(format t "~s~%" (multiple-value-list (macroexpand '(not-a-macro 1))))
