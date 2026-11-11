(let ((value 0))
  (tagbody
     (unwind-protect (go wrong) (setq value 7) (go done))
   wrong (setq value "unreachable")
   done)
  (print (1+ value)))

(print
 (car (block done
        (unwind-protect
             (unwind-protect (return-from done 1) (return-from done "inner"))
          (return-from done (cons 2 3))))))

(print
 (multiple-value-list
  (block done
    (unwind-protect (return-from done (values 1 2))
      (return-from done (values))))))

(let ((value 0))
  (flet ((escape () (throw 'escape :ignored)))
    (declare (notinline escape))
    (catch 'escape
      (tagbody
         (unwind-protect (escape) (setq value "changed") (go done))
         (setq value 7)
       done
         (print (length value))))))

(let ((counter 0))
  (print
   (block done
     (unwind-protect (return-from done 7)
       (tagbody again
          (incf counter)
          (when (< counter 3) (go again))))))
  (print counter))

(dolist (choose '(t nil))
  (let ((value 0) (counter 0))
    (tagbody again
       (unwind-protect
            (if (>= counter 3) (go done) (setq value (cons counter nil)))
         (incf counter)
         (when (< counter 2) (setq value "retry") (go again))
         (when choose (setq value 7)))
       (go again)
     done)
    (print value)
    (print counter)))

(print
 (multiple-value-list
  (block done
    (unwind-protect (return-from done 1)
      (return-from done (values "cleanup" 9))))))

(let ((events nil))
  (print
   (block done
     (unwind-protect
          (unwind-protect (return-from done :original)
            (push :inner events)
            (return-from done :replacement))
       (push :outer events))))
  (print (reverse events)))
