;; Allocation and a moving GC (SemiSpace): live objects in Lisp frames and in
;; dynamic-environment entries must survive and be updated.
(defun make-range (n)
  (let ((acc nil))
    (tagbody
     top
       (if (= n 0) (go done))
       (setq acc (cons n acc))
       (setq n (- n 1))
       (go top)
     done)
    acc))

(defun sum (l)
  (let ((s 0))
    (tagbody
     top
       (if (null l) (go done))
       (setq s (+ s (car l)))
       (setq l (cdr l))
       (go top)
     done)
    s))

(defun churn (n)
  (tagbody
   top
     (if (= n 0) (go done))
     (make-range 100)
     (setq n (- n 1))
     (go top)
   done)
  nil)

;; A live list in this frame across many collections.
(defun keep-alive (n)
  (let ((live (make-range n)))
    (churn 50000)
    (sum live)))

;; Live conses in every frame of a deep recursion.
(defun deep (n)
  (if (= n 0)
      nil
      (let ((c (cons n n)))
        (churn 10)
        (let ((rest (deep (- n 1))))
          (cons (car c) rest)))))

(print (keep-alive 1000))
(print (sum (deep 500)))
(print (list 1 (cons 2 3) (list 4 (list 5)) nil))
(%gc)
(print (> (%gc-count) 0))

;; A heap object as a catch tag: the entry's tag field is a GC root.
(print (let ((tag (cons 1 2)))
         (catch tag
           (churn 2000)
           (throw tag 'heap-tag-ok))))

;; A heap object thrown through an unwind-protect whose cleanup allocates.
(defun thrower (x) (throw 'k (list x x)))
(print (catch 'k
         (unwind-protect (thrower 7)
           (churn 2000))))

(defun add3 (a b c) (+ a (+ b c)))
(print (funcall #'add3 1 2 3))
(print (consp (cons 1 2)))
(print (atom 5))
(print (car nil))
