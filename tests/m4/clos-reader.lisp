;;; The reader (Eclector) and readtables.

(defun rs (string) (read-from-string string))
(defun show (string)
  (let ((*print-readably* nil))
    (format t "~s => ~s~%" string (multiple-value-list (read-from-string string)))))

(dolist (s '("42" "-17" "#x1F" "#b101" "#o17" "#36rZZ" "123456789012345678901234567890"
             "3/4" "-6/8" "1.5" "1.5d0" "0.1" "1e10" "-2.5e-3" "1.0d300"
             "foo" "FOO" "|Foo|" "f\\oo" ":key" "cl:car" "kiln.kernel::%put"
             "\"a string\"" "\"esc\\\"aped\"" "#\\a" "#\\Space" "#\\Newline"
             "(1 2 3)" "(a . b)" "(a b . c)" "'x" "#'car" "#(1 2 3)" "#*1011"
             "`(a ,b ,@c)" "#:gensym" "#+kiln yes" "#-kiln no yes" "  ; comment
 after" "#| block |# x" "#p\"/a/b.c\"" "#2A((1 2) (3 4))" "(#1=(x) #1#)"))
  (show s))

;;; Several objects from one string, and the second value.
(let ((string "a (b c) 3"))
  (loop with start = 0
        for (object end) = (multiple-value-list (read-from-string string nil :eof :start start))
        until (eq object :eof)
        do (format t "~s at ~d~%" object end)
           (setf start end)))

;;; From a stream.
(with-input-from-string (s "(defun f (x) (* x 2)) #.not-evaluated-here")
  (format t "~s~%" (read s))
  (format t "~s~%" (read-char s)))

;;; Errors are reader errors.
(dolist (s '("(1 2" ")" "#<foo>" "pkg-does-not-exist::x" "1 . 2"))
  (handler-case (progn (read-from-string s) (format t "no error: ~s~%" s))
    (reader-error (c) (format t "reader-error ~s~%" s))
    (end-of-file (c) (format t "end-of-file ~s~%" s))
    (error (c) (format t "error ~a ~s~%" (type-of c) s))))
(format t "~s~%" (read-from-string "" nil :none))

;;; Readtables.
(format t "~s ~s~%" (readtablep *readtable*) (typep *readtable* 'readtable))
(format t "~s~%" (readtable-case *readtable*))
(let ((*readtable* (copy-readtable)))
  (setf (readtable-case *readtable*) :preserve)
  (format t "~s~%" (symbol-name (rs "Hello"))))
(let ((*readtable* (copy-readtable)))
  (setf (readtable-case *readtable*) :invert)
  (format t "~s ~s~%" (symbol-name (rs "hello")) (symbol-name (rs "Hello"))))
(let ((*readtable* (copy-readtable nil)))
  (set-macro-character #\! (lambda (stream char)
                             (declare (ignore char))
                             (list 'bang (read stream t nil t))))
  (format t "~s~%" (rs "!x"))
  (set-dispatch-macro-character #\# #\! (lambda (stream sub arg)
                                          (declare (ignore sub))
                                          (list 'hash-bang arg (read stream t nil t))))
  (format t "~s~%" (rs "#3!y"))
  (set-syntax-from-char #\% #\;)
  (format t "~s~%" (rs "% ignored
 z")))
(format t "~s~%" (rs "!x"))
(format t "~s~%" (mapcar #'functionp (multiple-value-list (get-macro-character #\())))
(format t "~s~%" (functionp (get-dispatch-macro-character #\# #\()))
(with-standard-io-syntax
  (format t "~s ~s~%" (readtablep *readtable*) (readtable-case *readtable*)))

;;; Reading what the printer printed.
(let ((objects (list 1 -2/3 1.25 2.5d0 "str" #\x 'sym :kw '(1 (2 . 3) #(4 5)) (pathname "/x/y.z"))))
  (format t "~s~%" (every (lambda (o) (equalp o (rs (prin1-to-string o)))) objects)))

;;; Backquote forms expand at run time too.
(format t "~s~%" (macroexpand (rs "`(a ,b ,@c)")))
