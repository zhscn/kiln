(in-package #:cl-user)

(assert (null uiop/pathname:*unspecific-pathname-type*))
(let ((path (uiop:subpathname #P"/tmp/" "version")))
  (assert (string= "version" (pathname-name path)))
  (assert (null (pathname-type path)))
  (assert (string= "/tmp/version" (namestring path))))
(multiple-value-bind (output error-output status)
    (uiop:run-program '("/bin/sh" "-c" "printf '%s' \"$1\"; printf err >&2; exit 7"
                        "sh" "a b; c")
                      :output :string :error-output :string :ignore-error-status t)
  (assert (string= output "a b; c"))
  (assert (string= error-output "err"))
  (assert (= status 7)))
(assert (handler-case
            (progn (uiop:run-program '("/bin/sh" "-c" "exit 8")) nil)
          (uiop:subprocess-error (condition)
            (= (uiop:subprocess-error-code condition) 8))))
(format t "~&ASDF-INTEGRATION-COMPLETED~%")
