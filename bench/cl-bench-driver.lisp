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

(defun bench-monotonic-microseconds ()
  #+(and sbcl linux)
  (multiple-value-bind (seconds nanoseconds)
      (sb-unix:clock-gettime sb-unix:clock-monotonic)
    (+ (* seconds 1000000) (floor nanoseconds 1000)))
  #+kiln (get-internal-real-time)
  #-(or kiln (and sbcl linux))
  (floor (* (get-internal-real-time) 1000000) internal-time-units-per-second))

(defun split-words (string)
  (let ((words '()) (start nil))
    (loop for i from 0 to (length string)
          for c = (if (< i (length string)) (char string i) #\Space)
          do (cond ((char= c #\Space)
                    (when start (push (subseq string start i) words) (setf start nil)))
                   ((null start) (setf start i))))
    (nreverse words)))

(defun compile-gabriel ()
  (multiple-value-bind (path warnings failure) (cl-bench.misc:run-compiler)
    (declare (ignore warnings))
    (when (or failure (null path))
      (error "Compiling the Gabriel benchmarks failed."))
    path))

(defun selected-p (benchmark selection)
  (or (null selection)
      (member (getf benchmark :name) selection :test #'string-equal)
      (member (string (getf benchmark :group)) selection :test #'string-equal)))

(defun shared-clos-case-p (benchmark)
  (eql 0 (search "CLOS/" (getf benchmark :name) :test #'char-equal)))

(defun benchmark-disabled-p (benchmark name)
  (and (intersection (getf benchmark :disabled-for) *features*)
       #+sbcl
       (not (and (string= name "walk-list/mess")
                 (bench-getenv "BENCH_SBCL_LARGE_STACK")))
       #-sbcl
       t))

(defun run-benchmark (benchmark budget &optional (report-timing t))
  (let ((name (getf benchmark :name))
        (group (string-downcase (string (getf benchmark :group)))))
    (flet ((report (control &rest args)
             (format t "~&~A ~A ~?~%" name group control args)
             (finish-output)))
      (cond ((benchmark-disabled-p benchmark name)
             (report "SKIPPED disabled for this implementation"))
            (t
             (handler-case
                 (let ((setup (getf benchmark :setup))
                       (function (if (string= name "compiler") #'compile-gabriel
                                     (getf benchmark :function)))
                       (runs (getf benchmark :runs)))
                   (bench-gc)
                   (when setup
                     (if (listp setup) (eval setup) (funcall setup)))
                   (when (string= name "load-fasl") (compile-gabriel))
                   (let ((start (bench-monotonic-microseconds))
                         (budget-microseconds (* budget 1000000))
                         (done 0))
                     (loop while (< done runs)
                           do (funcall function)
                              (incf done)
                           until (>= (- (bench-monotonic-microseconds) start)
                                     budget-microseconds))
                     (when report-timing
                       (let* ((elapsed (- (bench-monotonic-microseconds) start))
                              (microseconds (round elapsed done)))
                         (multiple-value-bind (milliseconds fraction) (floor microseconds 1000)
                           (report "~D.~3,'0D ~D" milliseconds fraction done))))))
               (error (e)
                 (report "ERROR ~A"
                         (substitute #\Space #\Newline
                                     (handler-case (princ-to-string e)
                                       (error () "(unprintable)")))))))))))

(let* ((selection (let ((s (bench-getenv "BENCH_SELECT"))) (and s (split-words s))))
       (budget (let ((s (bench-getenv "BENCH_BUDGET")))
                 (if s (parse-integer s) 2)))
       (list-only (bench-getenv "BENCH_LIST"))
       (benchmarks (reverse *benchmarks*))
       (last-clos (unless list-only
                    (find-if (lambda (case)
                               (and (shared-clos-case-p case) (selected-p case selection)))
                             benchmarks :from-end t))))
  (dolist (benchmark benchmarks)
    (let ((selected (selected-p benchmark selection)))
      (cond (list-only
             (when selected
               (format t "~&~A ~(~A~)~%" (getf benchmark :name) (getf benchmark :group))))
            ((or selected (and last-clos (shared-clos-case-p benchmark)))
             (run-benchmark benchmark budget selected))))
    (when (eq benchmark last-clos)
      (setf last-clos nil))))
