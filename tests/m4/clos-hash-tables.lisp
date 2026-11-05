;;; Hash tables (Salmagundi) with identity hashes that survive moving
;;; collections.

(defclass thing () ((n :initarg :n :reader n)))

(let ((eq-table (make-hash-table :test 'eq))
      (eql-table (make-hash-table))
      (equal-table (make-hash-table :test 'equal))
      (equalp-table (make-hash-table :test #'equalp))
      (things (loop for i below 200 collect (make-instance 'thing :n i))))
  ;; EQ keys: instances, symbols, conses.
  (dolist (thing things)
    (setf (gethash thing eq-table) (n thing)))
  (setf (gethash 'a eq-table) 'symbol-a)
  (let ((cons (list 1 2)))
    (setf (gethash cons eq-table) 'the-cons)
    ;; Allocate to move objects around.
    (dotimes (i 20000) (make-list 10))
    (kiln.sys:%gc)
    (print (list (hash-table-count eq-table)
                 (loop for thing in things always (= (gethash thing eq-table) (n thing)))
                 (gethash 'a eq-table)
                 (gethash cons eq-table)
                 (gethash (list 1 2) eq-table)
                 (multiple-value-list (gethash 'missing eq-table 'default)))))
  ;; EQL: numbers and characters.
  (setf (gethash 1 eql-table) 'one
        (gethash (expt 2 100) eql-table) 'big
        (gethash 1.5 eql-table) 'float
        (gethash #\x eql-table) 'char)
  (print (list (gethash 1 eql-table) (gethash (expt 2 100) eql-table)
               (gethash 1.5 eql-table) (gethash #\x eql-table) (gethash 1.0 eql-table)))
  ;; EQUAL: strings and lists.
  (setf (gethash "abc" equal-table) 1
        (gethash '(1 (2 3)) equal-table) 2)
  (print (list (gethash (concatenate 'string "ab" "c") equal-table)
               (gethash (list 1 (list 2 3)) equal-table)
               (gethash "ABC" equal-table)))
  ;; EQUALP: case-insensitive strings, numbers of any type.
  (setf (gethash "Hello" equalp-table) 'hello
        (gethash 1 equalp-table) 'one)
  (print (list (gethash "HELLO" equalp-table) (gethash 1.0 equalp-table)
               (hash-table-test equalp-table)))
  ;; Growth, REMHASH, MAPHASH, CLRHASH, the iterator.
  (let ((table (make-hash-table)))
    (dotimes (i 1000) (setf (gethash i table) (* i i)))
    (dotimes (i 500) (remhash (* 2 i) table))
    (print (list (hash-table-count table) (gethash 999 table) (gethash 998 table)
                 (hash-table-p table) (hash-table-p 5)))
    (let ((sum 0))
      (maphash (lambda (k v) (declare (ignore v)) (incf sum k)) table)
      (print sum))
    (let ((n 0))
      (with-hash-table-iterator (next table)
        (loop (multiple-value-bind (more k v) (next)
                (declare (ignore k v))
                (unless more (return))
                (incf n))))
      (print n))
    (clrhash table)
    (print (hash-table-count table)))
  (print (list (= (sxhash "abc") (sxhash (copy-seq "abc")))
               (= (sxhash '(1 2)) (sxhash (list 1 2)))
               (integerp (sxhash 'foo)))))
;; Iteration order is SBCL's: insertion order, freed places reused last
;; freed first (docs/11 §9).
(let ((h (make-hash-table)) (keys '()))
  (dolist (k '(a b c d e)) (setf (gethash k h) t))
  (remhash 'b h)
  (remhash 'd h)
  (setf (gethash 'x h) t (gethash 'y h) t (gethash 'z h) t)
  (maphash (lambda (k v) (declare (ignore v)) (push k keys)) h)
  (print (reverse keys)))
