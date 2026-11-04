;;; Arrays: native simple vectors and strings, Regalia for the rest.

;; Simple ones stay native.
(print (simple-vector-p (make-array 3 :initial-element 0)))
(print (simple-string-p (make-array 2 :element-type 'character :initial-element #\a)))
(print (make-array 3 :initial-contents '(a b c)))

;; Multidimensional
(let ((a (make-array '(2 3) :initial-contents '((1 2 3) (4 5 6)))))
  (print (array-rank a))
  (print (array-dimensions a))
  (print (array-total-size a))
  (print (aref a 1 2))
  (setf (aref a 0 1) 20)
  (print (list (aref a 0 1) (row-major-aref a 1)))
  (print (array-row-major-index a 1 1))
  (print (array-in-bounds-p a 1 3))
  (print (arrayp a))
  (print (vectorp a))
  (print (typep a '(array t (2 3))))
  (print (typep a 'simple-array))
  (print (handler-case (aref a 2 0) (error () 'out-of-bounds))))

;; Fill pointers and adjustable vectors
(let ((v (make-array 2 :adjustable t :fill-pointer 0)))
  (print (length v))
  (dotimes (i 5) (vector-push-extend (* i i) v))
  (print (length v))
  (print (fill-pointer v))
  (print (list (aref v 0) (aref v 4) (elt v 3)))
  (print (coerce v 'list))
  (print (vector-pop v))
  (print (length v))
  (print (adjustable-array-p v))
  (print (array-has-fill-pointer-p v))
  (print (vectorp v))
  (print (typep v 'simple-array))
  (print (position 9 v))
  (print (reverse v))
  (print (find 4 v)))

(let ((v (make-array 3 :fill-pointer 1 :initial-element 7)))
  (print (vector-push 8 v))
  (print (vector-push 9 v))
  (print (vector-push 10 v))
  (print (coerce v 'list)))

;; Strings with fill pointers
(let ((s (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)))
  (dolist (c '(#\h #\e #\l #\l #\o)) (vector-push-extend c s))
  (print (stringp s))
  (print (simple-string-p s))
  (print (string= s "hello"))
  (print (char s 1))
  (setf (char s 0) #\j)
  (print (string s))
  (print (equal s "jello"))
  (print (string-upcase s)))

;; Specialized element types
(let ((b (make-array 4 :element-type 'bit :initial-element 0)))
  (setf (bit b 2) 1)
  (print (coerce b 'list))
  (print (array-element-type b))
  (print (bit-vector-p b))
  (print (handler-case (progn (setf (aref b 0) 2) 'stored) (type-error () 'type-error))))
(let ((u (make-array 3 :element-type '(unsigned-byte 8) :initial-element 255)))
  (print (array-element-type u))
  (print (aref u 2)))
(let ((f (make-array '(2 2) :element-type 'double-float)))
  (print (aref f 1 1)))
(print (upgraded-array-element-type '(integer 0 100)))
(print (upgraded-array-element-type 'base-char))
(print (upgraded-array-element-type 'symbol))

;; Displaced arrays
(let* ((base (make-array 6 :initial-contents '(0 1 2 3 4 5)))
       (d (make-array '(2 2) :displaced-to base :displaced-index-offset 2)))
  (print (aref d 1 0))
  (setf (aref d 0 0) 'two)
  (print (aref base 2))
  (print (multiple-value-list (array-displacement d))))

;; ADJUST-ARRAY keeps the elements.
(let ((a (make-array '(2 2) :adjustable t :initial-contents '((1 2) (3 4)))))
  (adjust-array a '(3 3) :initial-element 0)
  (print (list (aref a 0 0) (aref a 0 1) (aref a 1 0) (aref a 1 1) (aref a 2 2)))
  (print (array-dimensions a)))

;; SUBTYPEP on array types
(print (multiple-value-list (subtypep '(simple-array character (*)) 'string)))
(print (multiple-value-list (subtypep '(vector bit) 'bit-vector)))
