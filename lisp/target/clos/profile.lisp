;;;; The sampling profiler (docs/14 §5; rust/kiln-rt/src/profile.rs). The
;;;; PROFILE operations of the :FRAME primop start and stop it, and read
;;;; the samples: each a weight (timer ticks, or bytes in :ALLOC mode) and
;;;; the functions on the stack, innermost first, named here from their
;;;; debug info objects (debug.lisp).

(in-package #:kiln.kernel)

(defvar *profile-mode* :cpu)
(defvar *profile-interval* 1000)

(defun kiln.sys:start-profiler (&key (mode :cpu) (interval 1000))
  "Starts sampling, forgetting the earlier samples. MODE :CPU samples the
stack every INTERVAL microseconds of real time (at the next poll point);
:ALLOC samples it at each refill of the allocation buffer, weighted by
the bytes allocated."
  (check-type mode (member :cpu :alloc))
  (check-type interval (integer 50))
  (setf *profile-mode* mode *profile-interval* interval)
  (kiln.sys:%primop :frame 32 (if (eq mode :alloc) 1 0) interval)
  nil)

(defun kiln.sys:stop-profiler ()
  (kiln.sys:%primop :frame 33 0 0)
  nil)

(defun kiln.sys:profile-samples ()
  "The samples of the last profile, heaviest first: (WEIGHT . NAMES),
NAMES the names of the functions on the stack, innermost first."
  (loop for i below (kiln.sys:%primop :frame 34 0 0)
        collect (cons (kiln.sys:%primop :frame 35 i 0)
                      (loop for j below (kiln.sys:%primop :frame 36 i 0)
                            collect (let ((info (kiln.sys:%primop :frame 37 i j)))
                                      (if info (svref info 0) '?))))))

(defun profile-weight-string (weight)
  (if (eq *profile-mode* :alloc)
      (format nil "~,1F MB" (/ weight 1048576.0))
      (format nil "~,1F ms" (/ (* weight *profile-interval*) 1000.0))))

(defun kiln.sys:profile-report (&key (stream *standard-output*) (limit 30)
                                     (samples (kiln.sys:profile-samples)))
  "Prints the functions of the last profile by their own weight (the
samples where they are innermost) and by their total weight (the samples
where they are on the stack)."
  (let ((self (make-hash-table :test 'equal))
        (total (make-hash-table :test 'equal))
        (sum 0))
    (dolist (sample samples)
      (let ((weight (car sample)) (names (cdr sample)))
        (incf sum weight)
        (when names (incf (gethash (first names) self 0) weight))
        (dolist (name (remove-duplicates names :test #'equal))
          (incf (gethash name total 0) weight))))
    (format stream "~&Profile (~(~A~)): ~A in ~D stacks~%"
            *profile-mode* (profile-weight-string sum) (length samples))
    (flet ((table (title table)
             (let ((rows '()))
               (maphash (lambda (name weight) (push (cons name weight) rows)) table)
               (setf rows (sort rows #'> :key #'cdr))
               (format stream "~%  ~A~%" title)
               (loop for (name . weight) in rows
                     repeat limit
                     do (format stream "  ~6,2F% ~12@A  ~A~%"
                                (if (zerop sum) 0 (/ (* weight 100.0) sum))
                                (profile-weight-string weight)
                                (let ((*print-length* 6) (*print-level* 3))
                                  (let ((s (prin1-to-string name)))
                                    (if (> (length s) 100) (subseq s 0 100) s))))))))
      (table "By own weight:" self)
      (table "By total weight (on the stack):" total))
    (values)))

(defun kiln.sys:write-folded-stacks (pathname &key (samples (kiln.sys:profile-samples)))
  "Writes the samples of the last profile as folded stacks (outermost
function first, separated by semicolons, then the weight), the input of
flame graph tools."
  (with-open-file (out pathname :direction :output :if-exists :supersede)
    (dolist (sample samples)
      (format out "~{~A~^;~} ~D~%"
              (mapcar (lambda (name)
                        (substitute #\: #\; (let ((*print-length* 6) (*print-level* 3))
                                              (prin1-to-string name))))
                      (reverse (cdr sample)))
              (car sample))))
  pathname)

(defmacro kiln.sys:with-profiling ((&key (mode :cpu) (interval 1000) (report t) folded)
                                   &body body)
  "Runs BODY under the profiler, then prints the report (REPORT) and
writes the folded stacks to FOLDED, a pathname."
  `(progn
     (kiln.sys:start-profiler :mode ,mode :interval ,interval)
     (unwind-protect (progn ,@body)
       (kiln.sys:stop-profiler)
       (let ((samples (kiln.sys:profile-samples)))
         (when ,report (kiln.sys:profile-report :samples samples))
         (let ((folded ,folded))
           (when folded (kiln.sys:write-folded-stacks folded :samples samples)))))))
