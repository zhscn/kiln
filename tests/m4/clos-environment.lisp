(print (every (lambda (function)
                (let ((values (multiple-value-list (funcall function))))
                  (and (= (length values) 1)
                       (or (null (first values)) (stringp (first values))))))
              (list #'lisp-implementation-type #'lisp-implementation-version
                    #'software-type #'software-version #'machine-instance
                    #'machine-type #'machine-version #'short-site-name #'long-site-name)))
(print (every (lambda (function)
                (let ((value (funcall function)))
                  (and (stringp value) (plusp (length value)))))
              (list #'lisp-implementation-type #'lisp-implementation-version
                    #'software-type #'software-version #'machine-instance #'machine-type)))
(print (and (null (short-site-name)) (null (long-site-name))))
(print (every (lambda (function)
                (handler-case (progn (funcall function nil) nil)
                  (program-error () t)))
              (list #'lisp-implementation-type #'lisp-implementation-version
                    #'software-type #'software-version #'machine-instance
                    #'machine-type #'machine-version #'short-site-name #'long-site-name)))
(let ((model (with-open-file (stream "/proc/cpuinfo" :if-does-not-exist nil)
               (when stream
                 (loop for line = (read-line stream nil)
                       while line
                       when (eql (search "model name" line) 0)
                         return (string-trim '(#\Space #\Tab)
                                             (subseq line (1+ (position #\: line)))))))))
  (print (or (null model) (equal model (machine-version)))))
#+kiln
(let ((kiln.kernel::*short-site-name* "Test site")
      (kiln.kernel::*long-site-name* "Test site, full name"))
  (print (and (equal (short-site-name) "Test site")
              (equal (long-site-name) "Test site, full name"))))
#-kiln
(let ((sb-impl::*short-site-name* "Test site")
      (sb-impl::*long-site-name* "Test site, full name"))
  (print (and (equal (short-site-name) "Test site")
              (equal (long-site-name) "Test site, full name"))))
