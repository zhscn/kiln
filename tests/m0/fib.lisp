;; Recursion and fixnum arithmetic.
(defun fib (n)
  (if (< n 2)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))

(print (fib 25))
(print (* -7 6))
