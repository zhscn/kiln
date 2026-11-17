(in-package #:cl-user)

(assert (null uiop/pathname:*unspecific-pathname-type*))
(let ((path (uiop:subpathname #P"/tmp/" "version")))
  (assert (string= "version" (pathname-name path)))
  (assert (null (pathname-type path)))
  (assert (string= "/tmp/version" (namestring path))))
(format t "~&ASDF-INTEGRATION-COMPLETED~%")
