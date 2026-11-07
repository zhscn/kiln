;;; kiln's harness for cl-bench (bench/README.md), after cl-bench's files
;;; and tests.lisp: runs the benchmarks named by the environment variable
;;; BENCH_SELECT (names or groups, separated by spaces; all if unset), each
;;; up to its number of runs or until BENCH_BUDGET seconds (default 2) have
;;; passed, and prints for each a line
;;;   NAME GROUP MILLISECONDS-PER-RUN RUNS
;;; or NAME GROUP ERROR MESSAGE, NAME GROUP SKIPPED REASON. With
;;; BENCH_LIST set, it only prints the selected benchmarks' names and
;;; groups.

(in-package :cl-bench)

(defun bench-getenv (name)
  (let ((value #+sbcl (sb-ext:posix-getenv name)
               #+kiln (kiln.kernel::sys-string 10 (kiln.kernel::string-octets name))
               #-(or sbcl kiln) nil))
    (and (stringp value) (plusp (length value)) value)))

(defun bench-gc ()
  #+sbcl (sb-ext:gc :full t)
  #+kiln (kiln.sys:%gc))

(defun split-words (string)
  (let ((words '()) (start nil))
    (loop for i from 0 to (length string)
          for c = (if (< i (length string)) (char string i) #\Space)
          do (cond ((char= c #\Space)
                    (when start (push (subseq string start i) words) (setf start nil)))
                   ((null start) (setf start i))))
    (nreverse words)))

;;; Benchmarks that need what the harness does not run: COMPILE-FILE and
;;; LOAD of a fasl.
(defparameter *not-run* '("compiler" "load-fasl"))

(defun selected-p (benchmark selection)
  (or (null selection)
      (member (getf benchmark :name) selection :test #'string-equal)
      (member (string (getf benchmark :group)) selection :test #'string-equal)))

(defun run-benchmark (benchmark budget)
  (let ((name (getf benchmark :name))
        (group (string-downcase (string (getf benchmark :group)))))
    (flet ((report (control &rest args)
             (format t "~&~A ~A ~?~%" name group control args)
             (finish-output)))
      (cond ((member name *not-run* :test #'string=)
             (report "SKIPPED not supported by the harness"))
            ((intersection (getf benchmark :disabled-for) *features*)
             (report "SKIPPED disabled for this implementation"))
            (t
             (handler-case
                 (let ((setup (getf benchmark :setup))
                       (function (getf benchmark :function))
                       (runs (getf benchmark :runs)))
                   (bench-gc)
                   (when setup
                     (if (listp setup) (eval setup) (funcall setup)))
                   (let ((start (get-internal-real-time))
                         (done 0))
                     (loop while (< done runs)
                           do (funcall function)
                              (incf done)
                           until (>= (- (get-internal-real-time) start)
                                     (* budget internal-time-units-per-second)))
                     (report "~,3F ~D"
                             (/ (* (- (get-internal-real-time) start) 1000.0d0)
                                internal-time-units-per-second done)
                             done)))
               (error (e)
                 (report "ERROR ~A"
                         (substitute #\Space #\Newline
                                     (handler-case (princ-to-string e)
                                       (error () "(unprintable)")))))))))))

(let ((selection (let ((s (bench-getenv "BENCH_SELECT"))) (and s (split-words s))))
      (budget (let ((s (bench-getenv "BENCH_BUDGET")))
                (if s (parse-integer s) 2))))
  (dolist (benchmark (reverse *benchmarks*))
    (when (selected-p benchmark selection)
      ;; BENCH_LIST: only the names and groups, for tools/bench.sh, which
      ;; runs each benchmark in a process of its own.
      (if (bench-getenv "BENCH_LIST")
          (format t "~&~A ~(~A~)~%" (getf benchmark :name) (getf benchmark :group))
          (run-benchmark benchmark budget)))))
