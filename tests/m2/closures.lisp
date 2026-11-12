;; Closures, captured and assigned variables, local functions.
(defun make-counter (start)
  (lambda () (setq start (+ start 1)) start))

(defun make-adder (n) (lambda (x) (+ x n)))

(let ((c (make-counter 10)))
  (funcall c)
  (funcall c)
  (print (funcall c)))

(print (funcall (make-adder 5) 37))

;; Two closures sharing one cell.
(defun make-pair ()
  (let ((x 0))
    (cons (lambda () (setq x (+ x 1)))
          (lambda () x))))

(let ((p (make-pair)))
  (funcall (car p))
  (funcall (car p))
  (print (funcall (cdr p))))

;; Recursive local functions.
(defun sum-to (n)
  (labels ((walk (i acc) (if (> i n) acc (walk (+ i 1) (+ acc i)))))
    (walk 0 0)))
(print (sum-to 100))

(labels ((even-p (n) (if (= n 0) t (odd-p (- n 1))))
         (odd-p (n) (if (= n 0) nil (even-p (- n 1)))))
  (print (even-p 10))
  (print (odd-p 7)))

;; Closures stay valid across GCs (they live in the heap and move).
(defun build (n)
  (if (= n 0) nil (cons (make-adder n) (build (- n 1)))))
(defun apply-all (fs x)
  (if (null fs) nil (cons (funcall (car fs) x) (apply-all (cdr fs) x))))
(let ((fs (build 5)))
  (%gc)
  (print (apply-all fs 100)))

;; Primitive and global functions as values.
(defun twice (f x) (funcall f (funcall f x)))
(print (twice #'car '((1 2) 3)))
(defun make-adder-3 (x) (+ x 3))
(print (twice (function make-adder-3) 1))

;; A wide heap closure uses the allocation slow path and keeps all captures.
(defun make-wide-closure (a b c d e f g h i j k l m n o p cell)
  (lambda ()
    (list (+ a b c d e f g h i j k l m n o p) (car cell))))
(let ((f (make-wide-closure 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 (cons 7 8))))
  (%gc)
  (print (funcall f)))
