;;; The sampling profiler: CPU samples land in the busy function, weighted
;;; by time; allocation samples in the allocating one, weighted by bytes.

(defun show (x) (write-line (prin1-to-string x)))

(defun spin (n) (let ((s 0)) (dotimes (i n s) (setf s (logand (+ s i) #xffff)))))
(defun spin-outer () (dotimes (i 200) (spin 100000)))
(defvar *last* nil)
(defun allocate (n) (dotimes (i n) (setf *last* (make-list 10))))

(kiln.sys:start-profiler :mode :cpu :interval 1000)
(spin-outer)
(kiln.sys:stop-profiler)
(let* ((samples (kiln.sys:profile-samples))
       (total (reduce #'+ samples :key #'car))
       (spin (reduce #'+ (remove-if-not (lambda (s) (eq (cadr s) 'spin)) samples) :key #'car))
       (outer (reduce #'+ (remove-if-not (lambda (s) (member 'spin-outer (cdr s))) samples)
                      :key #'car)))
  (show (list (> total 10) (> spin (* 0.8 total)) (> outer (* 0.9 total)))))

(kiln.sys:start-profiler :mode :alloc)
(allocate 200000)
(kiln.sys:stop-profiler)
(let* ((samples (kiln.sys:profile-samples))
       (total (reduce #'+ samples :key #'car))
       (mine (reduce #'+ (remove-if-not (lambda (s) (member 'allocate (cdr s))) samples)
                     :key #'car)))
  ;; 200000 lists of 10 conses: 48 MB.
  (show (list (> total 40000000) (> mine (* 0.9 total)))))

(let ((s (with-output-to-string (*standard-output*)
           (kiln.sys:with-profiling () (spin 3000000)))))
  (show (and (search "By own weight" s) (search "SPIN" s) t)))
