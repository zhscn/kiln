;;; Benchmark: reading a source file (lisp/target/kernel.lisp) into concrete syntax
;;; trees with Eclector, and with READ; the same code runs in SBCL
;;; (tools/bench-fe-read.sh). Times in milliseconds.

(defun bench-read (path reader)
  (with-open-file (s path)
    (let ((count 0))
      (loop with eof = (list nil)
            for object = (funcall reader s eof)
            until (eq object eof)
            do (incf count))
      count)))

(defun bench-time (name thunk repeat)
  (funcall thunk)                       ; warm up the caches
  (let ((start (get-internal-real-time)))
    (dotimes (i repeat) (funcall thunk))
    (format t "~a: ~,1f ms~%" name
            (/ (- (get-internal-real-time) start)
               (* repeat (/ internal-time-units-per-second 1000))))))

(defun bench-main ()
  (let ((path "lisp/target/kernel.lisp"))
    (format t "~d forms~%" (bench-read path (lambda (s eof) (read s nil eof))))
    (bench-time "read" (lambda () (bench-read path (lambda (s eof) (read s nil eof)))) 3)
    (bench-time "cst read"
                (lambda () (bench-read path (lambda (s eof)
                                              (eclector.concrete-syntax-tree:read s nil eof))))
                3)
    (bench-time "read-line"
                (lambda () (with-open-file (s path)
                             (loop for line = (read-line s nil) while line)))
                3)))

(bench-main)
