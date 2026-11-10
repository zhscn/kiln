(let* ((calls nil)
       (request (list 'setf 'editor-probe))
       (#+kiln kiln.sys:*ed-functions* #+sbcl sb-ext:*ed-functions*
         (list (lambda (object) (push (list :first (eq object request)) calls) nil)
               (lambda (object) (push (list :second (eq object request)) calls) :accepted)
               (lambda (object) (declare (ignore object)) (error "Unexpected editor call.")))))
  (print (multiple-value-list (ed request)))
  (print (reverse calls)))
(let ((seen :unset)
      (#+kiln kiln.sys:*ed-functions* #+sbcl sb-ext:*ed-functions* nil))
  (setf #+kiln kiln.sys:*ed-functions* #+sbcl sb-ext:*ed-functions*
        (list (lambda (object) (setf seen object) t)))
  (print (ed))
  (print (null seen)))
(let ((#+kiln kiln.sys:*ed-functions* #+sbcl sb-ext:*ed-functions*
        (list (lambda (object) (declare (ignore object)) nil))))
  (print (handler-case (ed "source.lisp") (error () :no-editor))))
(let* ((path (parse-namestring "editor-missing-file.lisp"))
       (#+kiln kiln.sys:*ed-functions* #+sbcl sb-ext:*ed-functions*
         (list (lambda (object) (error 'file-error :pathname object)))))
  (print (handler-case (ed path)
           (file-error (condition) (eq path (file-error-pathname condition))))))
