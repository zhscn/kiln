;;; The braid: class metaobjects built by kiln's bootstrap, read through
;;; the accessor generic functions (early dispatch).

(in-package #:clostrophilia)

(defun names (classes) (mapcar #'class-name classes))

(print (class-name (find-class 'standard-class)))
(print (names (class-precedence-list (find-class 'standard-class))))
(print (names (class-precedence-list (find-class 'standard-generic-function))))
(print (names (class-precedence-list (find-class 'null))))
(print (mapcar #'slot-definition-name (class-slots (find-class 'standard-class))))
(print (mapcar #'slot-definition-location (class-slots (find-class 'standard-class))))
(print (class-name (class-of (find-class 'standard-class))))
(print (class-name (class-of (find-class 'cons))))
(print (names (mapcar #'class-of (list 1 'a "s" #\c '(1) nil 1.5 (expt 2 70)))))
(print (class-finalized-p (find-class 'standard-method)))
(print (names (class-direct-superclasses (find-class 'funcallable-standard-object))))
(print (generic-function-name #'class-name))
(print (length (generic-function-methods #'class-name)))
(print (eq (stamp (find-class 'class)) (unique-number (find-class 'standard-class))))
