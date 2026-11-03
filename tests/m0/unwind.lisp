;; CATCH/THROW across frames and UNWIND-PROTECT cleanups (try_call + runtime unwinder).
(defun thrower (x)
  (throw 'done (* x 10)))

(defun middle (x)
  (unwind-protect
       (+ 1 (thrower x))
    (print 'middle-cleanup)))

(defun deep (n)
  (if (= n 0)
      (throw 'deep 'bottom)
      (unwind-protect (deep (- n 1))
        (print n))))

;; Throw through a cleanup in another frame.
(print (catch 'done (middle 4)))

;; Several cleanups, innermost first.
(print (catch 'deep (deep 3)))

;; Catch and unwind-protect in the same frame; throw from a cleanup.
(print (catch 'outer
         (catch 'inner
           (unwind-protect (throw 'inner 1)
             (print 'cleanup-throws)
             (throw 'outer 2)))))

;; Normal exit runs the cleanup and keeps the value.
(print (unwind-protect 7 (print 'normal-cleanup)))

;; RETURN-FROM out of an unwind-protect runs the cleanup.
(defun early (x)
  (unwind-protect (if (> x 0) (return-from early 'positive) 'other)
    (print 'early-cleanup)))
(print (early 5))

;; Nested catches with the same tag: the innermost wins.
(print (catch 'x (+ 100 (catch 'x (throw 'x 1)))))

;; A local exit out of a cleanup that an unwind is running abandons the
;; unwind; the dynamic environment must be clean afterwards.
(defun abandon ()
  (block b
    (catch 'never
      (unwind-protect (throw 'never 1)
        (return-from b 'abandoned)))))
(print (abandon))
(print (catch 'z (throw 'z 'clean)))
