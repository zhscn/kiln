;; &optional, &rest, &key.
(defun opt (a &optional (b (+ a 1)) (c 10 c-p))
  (list a b c c-p))
(print (opt 1))
(print (opt 1 5))
(print (opt 1 5 6))

(defun rst (a &rest more) (list a more))
(print (rst 1))
(print (rst 1 2 3 4 5 6 7))

(defun keys (&key x (y 2) ((:zed z) 'none z-p))
  (list x y z z-p))
(print (keys))
(print (keys :y 20 :x 10))
(print (keys :zed 3 :zed 4))
(print (keys :x 1 :bogus 2 :allow-other-keys t))

(defun all (a &optional b &rest r &key k &allow-other-keys)
  (list a b r k))
(print (all 1 2 :k 3 :other 4))

;; Defaults may refer to earlier parameters and to special variables.
(defvar *default* 'dflt)
(defun dflt (&optional (x *default*)) x)
(print (dflt))
(let ((*default* 'rebound)) (print (dflt)))

;; Arguments beyond the registers, with GC while the rest list is consed.
(defun many (a b c d &rest r) (list a b c d r))
(print (many 1 2 3 4 5 6 7 8 9 10))
(print (apply #'many (list (list 1) (list 2) (list 3) (list 4) (list 5) (list 6))))

;; MULTIPLE-VALUE-BIND uses &optional.
(multiple-value-bind (q r) (values 7 3)
  (print (list q r)))

;; Closures with lambda lists.
(let ((f (lambda (&key (n 1)) (* n 2))))
  (print (funcall f))
  (print (funcall f :n 21)))
