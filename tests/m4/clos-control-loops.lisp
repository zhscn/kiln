(let ((value 0))
  (tagbody
     (tagbody (setq value 3) (go done))
     (setq value "unreachable")
   done)
  (print (1+ value)))

(defun nested-loop-value (limit initial)
  (let ((value initial) (counter 0) (cleanups 0))
    (values
     (block finish
       (tagbody again
          (when (>= counter limit) (return-from finish value))
          (unwind-protect
               (tagbody
                  (if (oddp counter) (setq value "odd") (setq value (cons counter nil)))
                  (incf counter)
                  (go again))
            (incf cleanups)
            (when (= counter 2) (setq value 99)))))
     cleanups)))
(dolist (limit '(0 1 2 7))
  (print (multiple-value-list (nested-loop-value limit :initial))))

(let ((value 0))
  (tagbody
     (unwind-protect
          (unwind-protect (go done) (setq value "inner"))
       (setq value 7))
   done)
  (print (1+ value)))

(let ((value 0))
  (print
   (block done
     (unwind-protect
          (tagbody
             (go use)
             (setq value "unreachable")
           use
             (return-from done value))
       (setq value "cleanup"))))
  (print (length value)))

(dolist (choose '(t nil))
  (let ((value 0))
    (print
     (multiple-value-list
      (block done
       (unwind-protect
            (if choose
                (progn (setq value 1) (return-from done (values 10 20)))
                (progn (setq value "changed") (return-from done (values 30 40))))
         (print (integerp value))))))
    (print value)))

(let ((value 0))
  (tagbody
     (list (progn (setq value 4) (go done)) (setq value "unreachable"))
   done)
  (print (1+ value)))

(let ((value 4611686018427387902) (counter 0))
  (block finish
    (tagbody again
       (tagbody
          (when (= counter 3) (return-from finish))
          (incf value)
          (incf counter)
          (go again))))
  (print value))
