;; TAGBODY/GO loops (poll points at loop headers), LET*, SETQ, BLOCK.
(defun sum-to (n)
  (let ((i 0) (acc 0))
    (tagbody
     top
       (if (> i n) (go done))
       (setq acc (+ acc i))
       (setq i (+ i 1))
       (go top)
     done)
    acc))

(defun find-first-square-above (limit)
  (let ((i 0))
    (tagbody
     again
       (if (> (* i i) limit) (return-from find-first-square-above i))
       (setq i (+ i 1))
       (go again))))

(print (sum-to 100000))
(print (find-first-square-above 1000))
(print (let* ((a 3) (b (* a a))) (- b a)))
