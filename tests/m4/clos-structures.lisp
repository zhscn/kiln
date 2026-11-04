;;; DEFSTRUCT (Anatomicl, expanded in the host).

(defstruct point x (y 0))
(let ((p (make-point :x 1)))
  (print (list (point-x p) (point-y p)))
  (setf (point-y p) 5)
  (print (point-y p))
  (print (point-p p))
  (print (point-p 3))
  (print (typep p 'point))
  (print (typep p 'structure-object))
  (let ((q (copy-point p)))
    (setf (point-x q) 10)
    (print (list (point-x p) (point-x q)))))

;; Options: conc-name, constructor with a BOA lambda list, read-only slots,
;; predicates.
(defstruct (account (:conc-name acct-)
                    (:constructor open-account (owner &optional (balance 100)))
                    (:predicate accountp))
  (owner nil :read-only t)
  (balance 0 :type integer))
(let ((a (open-account "ann")))
  (print (list (acct-owner a) (acct-balance a)))
  (incf (acct-balance a) 50)
  (print (acct-balance a))
  (print (accountp a)))

;; Inclusion
(defstruct (point3 (:include point (y 7))) (z 0))
(let ((p (make-point3 :x 1 :z 3)))
  (print (list (point3-x p) (point3-y p) (point3-z p)))
  (print (point-x p))
  (print (point-p p))
  (print (point3-p (make-point))))

;; Typed structures
(defstruct (pair (:type list)) left right)
(let ((p (make-pair :left 1 :right 2)))
  (print p)
  (print (pair-right p)))
(defstruct (tagged (:type vector) :named) a b)
(let ((v (make-tagged :a 'x :b 'y)))
  (print v)
  (print (tagged-p v))
  (print (tagged-b v)))

;; Uninitialized slots and copying through COPY-STRUCTURE
(defstruct blank a)
(print (blank-p (copy-structure (make-blank :a 1))))
(print (blank-a (copy-structure (make-blank :a 1))))

;; Structures as hash keys and in methods
(defgeneric area (shape))
(defstruct square side)
(defmethod area ((s square)) (* (square-side s) (square-side s)))
(print (area (make-square :side 4)))
(let ((h (make-hash-table)) (s (make-square :side 1)))
  (setf (gethash s h) 'found)
  (print (gethash s h)))
