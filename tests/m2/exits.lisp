;; Non-local RETURN-FROM and GO from closures, through cleanups.
(defun call (f) (funcall f))

(defun find-first-even (list)
  (block found
    (labels ((scan (l)
               (if (null l) nil
                   (progn (call (lambda () (if (= 0 (- (car l) (* 2 (truncate-2 (car l)))))
                                               (return-from found (car l)))))
                          (scan (cdr l))))))
      (scan list))
    'none))
(defun truncate-2 (n) (if (< n 2) 0 (+ 1 (truncate-2 (- n 2)))))

(print (find-first-even '(1 3 5 6 7 8)))
(print (find-first-even '(1 3)))

(defun count-down (n)
  (let ((steps 0))
    (tagbody
     top
       (setq steps (+ steps 1))
       (call (lambda ()
               (setq n (- n 1))
               (if (> n 0) (go top))))
       (print n))
    steps))
(print (count-down 5))

;; The non-local exit runs the cleanup in between.
(defun exit-through-cleanup ()
  (block b
    (unwind-protect
         (call (lambda () (return-from b 'returned)))
      (print 'cleanup))))
(print (exit-through-cleanup))

;; Exiting to a block that has already been exited is an error; not tested
;; here because it ends the process.

;; Local exits from inside unwind-protect and catch.
(defun local-exit ()
  (block b
    (catch 'k
      (unwind-protect (return-from b 'out) (print 'cleanup-2)))))
(print (local-exit))

;; Each activation has its own exit point: the closure from the first,
;; finished activation must not return into the second one.
(defvar *saved* nil)
(defun nest (depth)
  (block b
    (if (= depth 0)
        (setq *saved* (lambda () (return-from b 'stale)))
        (call (lambda () (return-from b depth))))))
(print (functionp (nest 0)))
(print (nest 2))
