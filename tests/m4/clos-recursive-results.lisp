(labels ((walk (n) (if (zerop n) (cons 1 2) (walk (1- n)))))
  (declare (notinline walk))
  (print (car (walk 5))))

(labels ((left (n) (if (zerop n) (cons 3 4) (right (1- n))))
         (right (n) (if (zerop n) (cons 5 6) (left (1- n)))))
  (declare (notinline left right))
  (print (car (left 5)))
  (print (car (left 6))))

(labels ((sum (n)
           (if (zerop n) 4611686018427387903 (+ 1 (sum (1- n))))))
  (declare (notinline sum))
  (print (+ (sum 3) 1)))

(labels ((sum (n) (if (zerop n) 0d0 (+ 1d0 (sum (1- n))))))
  (declare (notinline sum))
  (print (= (+ (sum 5) 2d0) 7d0)))

(labels ((walk (n)
           (block done
             (if (zerop n) (tagbody (return-from done "string"))
                 (walk (1- n)))
             (cons 1 2))))
  (declare (notinline walk))
  (print (length (walk 0)))
  (print (car (walk 3))))

(labels ((walk (n) (if (zerop n) (values) (walk (1- n)))))
  (declare (notinline walk))
  (print (multiple-value-list (walk 5))))

(let ((cleanups 0))
  (labels ((walk (n)
             (unwind-protect
                  (block done
                    (if (zerop n) (return-from done (cons 8 9)) (walk (1- n))))
               (incf cleanups))))
    (declare (notinline walk))
    (print (car (walk 3)))
    (print cleanups)))
