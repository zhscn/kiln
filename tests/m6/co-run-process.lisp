(let ((output (make-string-output-stream)))
  (assert (= (kiln.sys:run-process '("/bin/sh" "-c" "printf '%s' \"$1\"; exit 7"
                                    "sh" "a b; c")
                                  :output output)
             7))
  (assert (string= (get-output-stream-string output) "a b; c")))
(assert (handler-case
            (progn (kiln.sys:run-process '("/dev/null/missing")) nil)
          (error () t)))
(print :run-process)
