;;;; Frames: the names of the frames' functions, the source
;;;; positions of their calls and the variables known during the calls.

(defun show-frame (f)
  (multiple-value-bind (file start) (kiln.sys:frame-source f)
    (format t "~S ~A ~S~%" (kiln.sys:frame-name f)
            (and file (file-namestring file))
            (and start (multiple-value-list (kiln.sys:source-line file start)))))
  (format t "  ~S~%" (kiln.sys:frame-variables f)))

(defun show-frames (n)
  ;; The first frame is SHOW-FRAMES's own.
  (loop for f in (rest (kiln.sys:frame-list))
        for i below n
        do (show-frame f)))

(defun frames-a (x)
  (let ((y (* x 2)))
    (show-frames 4)
    (list x y)))

(defun frames-b (n)
  (flet ((helper (z) (frames-a (+ z 1))))
    (let ((r (helper n)))
      (list r n))))

(defgeneric frames-gf (x))

(defmethod frames-gf ((x integer))
  (let ((v (frames-b x)))
    (cons x v)))

(print (frames-gf 10))
(terpri)

;;; A closed-over variable that is assigned lives in a cell.
(defun frames-cell (k)
  (let ((count k))
    (flet ((bump () (incf count)))
      (bump)
      (show-frames 1)
      (bump)
      count)))

(print (frames-cell 5))
(terpri)

;;; The frames of an error, from its handler.
(defun frames-fail (x)
  (let ((cell (list x)))
    (car (car cell))))

(block done
  (handler-bind ((type-error
                   (lambda (c)
                     (declare (ignore c))
                     (let ((f (find 'frames-fail (kiln.sys:frame-list)
                                    :key #'kiln.sys:frame-name)))
                       (show-frame f))
                     (return-from done))))
    (frames-fail 7)))

;;; A lambda in a function.
(defun frames-map (list)
  (mapcar (lambda (e) (show-frames 1) e) list))

(frames-map '(1))
