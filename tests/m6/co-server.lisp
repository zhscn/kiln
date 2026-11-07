;;;; The back-end protocol, served from a string: tasks,
;;;; output, an error and its debug level, a nested task inside it,
;;;; evaluation in a frame, restarts with and without arguments.

(defparameter *requests* "
(:eval 1 \"(defun srv-f (x) (let ((y (* x 2))) (if (> y 10) (error \\\"too big: ~a\\\" y) (list x y))))\")
(:eval 2 \"(print :hi) (values (srv-f 2) 7)\")
(:eval 3 \"(srv-f 1) (srv-f 8)\")
(:frame 4 0)
(:eval 14 \"(defun srv-check (n) (when (> n 5) (error \\\"check ~a\\\" n)))\")
(:eval 15 \"(defun srv-h (x) (let ((y (+ x 1))) (srv-check y) (list x y)))\")
(:eval 16 \"(srv-h 9)\")
(:frame 17 1)
(:eval-in-frame 18 1 \"(* x y)\")
(:restart 19 0)
(:eval 5 \"(+ 1 2)\")
(:restart 6 0)
(:eval 7 \"(defun srv-g (n) (restart-case (error \\\"bad ~a\\\" n) (use-value (v) :report \\\"Use a value.\\\" v)))\")
(:eval 8 \"(list (srv-g 4) :done)\")
(:eval 9 \"(car 5)\")
(:restart 10 0)
(:restart 11 0 \"(* 6 7)\")
(:nonsense 12)
(:eval 13 \"(srv-g 5)\")
")

(defun show (message)
  ;; Frames carry file names and addresses: show their function names.
  (case (first message)
    (:debug
     (destructuring-bind (id level type report restarts frames output) (rest message)
       (format t "~S~%" (list :debug id level type report
                              (mapcar #'second restarts)
                              (mapcar #'second frames)
                              output))))
    (:frame
     (destructuring-bind (index name file line column variables) (third message)
       (declare (ignore file))
       (format t "~S~%" (list :frame (second message) index name line column variables))))
    (t (format t "~S~%" message))))

(let ((replies (with-output-to-string (out)
                 (kiln.sys:serve :input (make-string-input-stream *requests*)
                                 :output out))))
  (with-input-from-string (in replies)
    (loop for message = (read in nil nil)
          while message
          do (show message))))
