;; C8: Lisp code on a second stack. The GC scans every stack segment, and
;; an unwind from the new stack to a catch on the old one runs the cleanups
;; on both and leaves through the stack boundary.
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

;; Live data on the new stack across collections.
(defun on-other-stack (n)
  (let ((l (make-range n)))
    (churn 20000)
    (sum l)))

;; Live data on the old stack across collections that run on the new one.
(defun caller ()
  (let ((mine (make-range 100)))
    (let ((r (%call-on-new-stack #'on-other-stack 1000)))
      (list r (sum mine)))))

(print (caller))

;; Stacks on stacks.
(defun nest (n)
  (if (= n 0)
      (progn (churn 1000) 'bottom)
      (%call-on-new-stack #'nest (- n 1))))
(print (nest 5))

;; Throw from the new stack to the old one, through cleanups on both.
(defun inner-throw (x)
  (unwind-protect (throw 'out (list x 'from-new-stack))
    (print 'new-stack-cleanup)
    (churn 1000)))
(print (catch 'out
         (unwind-protect (%call-on-new-stack #'inner-throw 9)
           (print 'old-stack-cleanup)
           (churn 1000))))

;; Throw across several stacks.
(defun deep-throw (n)
  (if (= n 0)
      (throw 'top 'crossed)
      (%call-on-new-stack #'deep-throw (- n 1))))
(print (catch 'top (deep-throw 3)))

;; Segments are restored after unwinding off the new stacks.
(print (caller))
(%gc)
(print 'done)
