;;; Hash tables against a model, under random insertions and removals:
;;; contents, counts, and the iteration order (SBCL's: insertion order, a
;;; removed entry's place reused by the next insertion, the last freed
;;; first), for EQ, EQL, EQUAL and EQUALP tables.

(defun show (x) (write-line (prin1-to-string x)))

(defun model-run (test keys steps seed)
  (let ((table (make-hash-table :test test))
        (places (make-array 0 :adjustable t :fill-pointer 0)) ; key or :free
        (free '())
        (state (sb-random seed))
        (ok t))
    (dotimes (i steps)
      (let* ((key (elt keys (funcall state (length keys))))
             (place (position key places :test test)))
        (if (and place (zerop (funcall state 3)))
            (progn (remhash key table)
                   (setf (aref places place) :free)
                   (push place free))
            (progn (setf (gethash key table) i)
                   (unless place
                     (if free
                         (setf (aref places (pop free)) key)
                         (vector-push-extend key places)))))))
    (let ((expected (remove :free (coerce places 'list)))
          (actual '()))
      (maphash (lambda (k v) (declare (ignore v)) (push k actual)) table)
      (unless (equal (nreverse actual) expected) (setf ok (list :order test)))
      (unless (= (hash-table-count table) (length expected)) (setf ok (list :count test)))
      (dolist (k expected)
        (unless (nth-value 1 (gethash k table)) (setf ok (list :missing test k)))))
    ok))

;; A deterministic generator (no RANDOM dependence on the seed format).
(defun sb-random (seed)
  (let ((x seed))
    (lambda (n) (setf x (mod (+ (* x 1103515245) 12345) 2147483648)) (mod (ash x -8) n))))

(let ((symbols (loop for i below 300 collect (make-symbol (format nil "S~D" i))))
      (numbers (loop for i below 300 collect (if (evenp i) i (* i 1000000000000000000000))))
      (strings (loop for i below 300 collect (format nil "str~D" i))))
  (show (list (model-run 'eq symbols 20000 1)
              (model-run 'eql numbers 20000 2)
              (model-run 'equal strings 20000 3)
              (model-run 'equalp (mapcar #'string-upcase strings) 20000 4))))

;; Many entries, then all removed, then reused.
(let ((h (make-hash-table)))
  (dotimes (i 5000) (setf (gethash i h) (* i i)))
  (show (list (hash-table-count h) (gethash 4777 h)))
  (dotimes (i 5000) (remhash i h))
  (show (list (hash-table-count h) (gethash 4777 h)))
  (dotimes (i 10) (setf (gethash (- i) h) i))
  (let ((keys '())) (maphash (lambda (k v) (declare (ignore v)) (push k keys)) h)
    (show (nreverse keys)))
  (clrhash h)
  (setf (gethash 'a h) 1)
  (show (list (hash-table-count h) (gethash 'a h))))
