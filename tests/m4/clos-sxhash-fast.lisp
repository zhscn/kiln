;;; Direct SXHASH paths preserve the accumulating implementation's results.
(let* ((text "abcλ😀defghijklmnopqrstuvwxyz")
       (adjustable (make-array (length text) :element-type 'character
                               :initial-contents text :fill-pointer (length text)))
       (displaced (make-array 5 :element-type 'character :displaced-to text
                               :displaced-index-offset 2))
       (objects (list most-negative-fixnum most-positive-fixnum -1 0 1 99
                      (1- most-negative-fixnum) (1+ most-positive-fixnum)
                      #\a #\λ #\😀 nil t :keyword (make-symbol "abcλ")
                      "" "abcdefghij" text adjustable displaced
                      0.0 -0.0 1.25d0 2/3 #C(1 2)
                      (make-array 6 :element-type 'bit
                                    :initial-contents '(1 0 1 1 0 1))
                      '(a (1 . 2) "string") #(1 2 3))))
  (dolist (limit '(0 1 2 10 64))
    (let ((salmagundi::*hash-limit* limit))
      (dolist (object objects)
        (assert (= (sxhash object) (salmagundi::slow-sxhash object)))))))
(let ((text "abcdefghij"))
  (assert (= (sxhash text)
             (sxhash (make-array 12 :element-type 'character
                                    :initial-contents "abcdefghijXX" :fill-pointer 10))))
  (assert (= (sxhash (make-symbol text)) (sxhash (make-symbol text)))))
(print :sxhash-matches)
