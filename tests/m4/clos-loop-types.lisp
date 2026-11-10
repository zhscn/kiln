(defun loop-to-limit (limit)
  (declare (fixnum limit))
  (let ((counter 0))
    (tagbody top
       (if (>= counter limit) (go done))
       (setq counter (1+ counter))
       (go top)
     done)
    counter))
(print (mapcar #'loop-to-limit '(-2 0 1 10)))

(defun loop-near-limit (counter limit)
  (declare (fixnum counter limit))
  (tagbody top
     (if (>= counter limit) (go done))
     (setq counter (1+ counter))
     (go top)
   done)
  counter)
(print (loop-near-limit 4611686018427387901 4611686018427387903))
(print (loop-near-limit -4611686018427387904 -4611686018427387902))

(let ((value 1) (counter 0))
  (tagbody top
     (print (integerp value))
     (setq value "changed")
     (incf counter)
     (if (< counter 2) (go top)))
  (print (integerp value)))

(let ((value 1))
  (tagbody
     (go use)
     (setq value "unreachable")
   use
     (print (1+ value))))

(let ((value 4611686018427387903) (counter 0))
  (tagbody top
     (setq value (1+ value))
     (incf counter)
     (if (< counter 2) (go top)))
  (print value))

;;; Cleanup changes the value before the jump's destination is reached.
(let ((value 1) (counter 0))
  (tagbody top
     (unwind-protect (go use) (setq value "changed"))
   use
     (print (handler-case (1+ value) (type-error () 'type-error)))
     (setq value 1)
     (incf counter)
     (if (< counter 2) (go top))))

(let ((value 1))
  (tagbody
     (funcall (lambda () (go use)))
     (setq value "unreachable")
   use
     (print (1+ value))))

(let ((value 1))
  (tagbody
     (tagbody (setq value "changed") (go use))
     (setq value 5)
   use
     (print (integerp value))))

(defun loop-checked-entry (value)
  (let ((counter 0))
    (tagbody top
       (locally (declare (fixnum value)) (print (1+ value)))
       (setq value 1)
       (incf counter)
       (if (< counter 2) (go top)))))
(print (handler-case (loop-checked-entry "bad") (type-error () 'type-error)))

;;; Different backedges carry different value classes into the same header.
(let ((value 0) (counter 0))
  (tagbody
     (go left)
   left
     (print (integerp value))
     (setq value 0)
     (incf counter)
     (if (>= counter 3) (go done))
     (go right)
   right
     (print (integerp value))
     (setq value "changed")
     (incf counter)
     (if (< counter 3) (go left))
   done)
  (print (integerp value)))

(defun loop-return (limit)
  (declare (fixnum limit))
  (block done
    (let ((counter 0))
      (tagbody top
         (if (>= counter limit) (return-from done counter))
         (setq counter (1+ counter))
         (go top)))))
(print (mapcar #'loop-return '(-2 0 1 10)))

(let ((value 1))
  (tagbody
     (setq value (progn (go use) "unreachable"))
   use
     (print (1+ value))))
