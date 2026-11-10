;;; One-index access must use the dimension and follow current displacement.
(let* ((base (make-array 6 :element-type 'single-float :initial-element 1f0))
       (middle (make-array 4 :element-type 'single-float
                           :displaced-to base :displaced-index-offset 1))
       (view (make-array 2 :element-type 'single-float :fill-pointer 0
                         :displaced-to middle :displaced-index-offset 1)))
  (print (= (setf (aref view 1) 7f0) 7f0))
  (print (= (aref base 3) 7f0))
  (print (= (aref view 1) 7f0))
  (print (zerop (length view)))
  (print (handler-case (progn (setf (aref view 0) 7d0) nil)
           (type-error () t)))
  (print (= (aref base 2) 1f0)))

(let ((array (make-array 2 :element-type '(unsigned-byte 8)
                         :adjustable t :initial-element 4)))
  (adjust-array array 4 :initial-element 9)
  (print (aref array 3))
  (dolist (index '(-1 4 1/2 #\a 100000000000000000000))
    (print (handler-case (progn (aref array index) nil) (error () t)))
    (print (handler-case (progn (setf (aref array index) 3) nil) (error () t)))))

;;; Rank checks apply even when a row-major index would be in bounds.
(dolist (array (list (make-array nil :initial-element 0)
                    (make-array '(1 2) :initial-element 0)
                    (make-array 0 :element-type nil)))
  (print (handler-case (progn (aref array 0) nil) (error () t)))
  (print (handler-case (progn (setf (aref array 0) nil) nil) (error () t))))

(let ((array (make-array 1 :element-type 'base-char :initial-element #\a)))
  (print (char= (aref array 0) #\a))
  (print (handler-case (progn (setf (aref array 0) #\λ) nil) (type-error () t)))
  (print (char= (aref array 0) #\a)))
