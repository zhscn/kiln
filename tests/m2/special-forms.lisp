;; Every CL special operator (CLHS 3.1.2.1.2.1), not at top level.
(defvar *a* 'global-a)
(defvar *b* 'global-b)
(defun read-ab () (list *a* *b*))

(defun all-special-forms (x)
  (let ((results nil))
    (flet ((note (v) (setq results (cons v results))))
      ;; block, return-from
      (note (block b (return-from b 'block) 'not-reached))
      ;; catch, throw
      (note (catch 'k (throw 'k 'catch)))
      ;; eval-when (not at top level: only :execute counts)
      (note (eval-when (:compile-toplevel) 'never))
      (note (eval-when (:execute) 'eval-when))
      ;; function, labels
      (note (labels ((self (n) (if (= n 0) 'labels (self (- n 1))))) (funcall #'self 3)))
      ;; go, tagbody
      (note (let ((n 0)) (tagbody top (setq n (+ n 1)) (if (< n 3) (go top))) n))
      ;; if, let, let*, setq, progn, quote, the
      (note (let* ((p 1) (q (+ p 1))) (setq p (the fixnum (+ p q))) (progn 'ignored (list p q))))
      ;; load-time-value: evaluated once, at load time
      (note (load-time-value (cons 'ltv 'once)))
      ;; locally
      (note (locally (declare (special *a*)) *a*))
      ;; macrolet, symbol-macrolet
      (note (macrolet ((m (y) (list 'quote (list y y)))) (m mac)))
      (note (symbol-macrolet ((s (car x))) (list s 'symbol-macrolet)))
      ;; multiple-value-call, multiple-value-prog1
      (note (multiple-value-call #'list (values 1 2) (multiple-value-prog1 (values 3 4) (values 5))))
      ;; progv
      (note (progv '(*a* *b*) '(dyn-a) (list (car (list *a*)) (boundp '*b*))))
      (catch 'k (progv '(*a* *b*) '(thrown thrown) (throw 'k nil)))
      (note (read-ab))
      ;; unwind-protect
      (note (let ((log nil))
              (catch 'k (unwind-protect (throw 'k nil) (setq log 'unwind-protect)))
              log)))
    results))

(defun print-all (l) (when l (print (car l)) (print-all (cdr l))))
(defun my-reverse (l acc) (if l (my-reverse (cdr l) (cons (car l) acc)) acc))
(print-all (my-reverse (all-special-forms (list 'x)) nil))
;; The load-time value is the same object on every call.
(defun ltv () (load-time-value (list 1)))
(print (eq (ltv) (ltv)))

;; SETQ and SETF of symbol macros act on the expansion.
(let ((cell (list 1 2)))
  (symbol-macrolet ((head (car cell)) (tail (cdr cell)))
    (setq head 10)
    (setf tail '(20))
    (incf head)
    (print cell)))
