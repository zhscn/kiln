(dolist (options '((:type (vector single-float))
                   (:type (vector bit))
                   (:type (vector character))
                   (:type (vector integer))
                   (:type (vector (member only-this-symbol)))))
  (print (handler-case
             (progn (macroexpand-1
                     `(defstruct (invalid-named-structure ,options :named)))
                    :accepted)
           (simple-error () :rejected))))
(dolist (type '(list vector (vector t) (vector single-float)))
  (print (handler-case
             (progn (macroexpand-1
                     `(defstruct (invalid-predicate-structure
                                  (:type ,type) (:predicate invalid-predicate))))
                    :accepted)
           (simple-error () :rejected))))
(defstruct (named-symbol-vector (:type (vector symbol)) :named)
  (value 'hello :type symbol))
(defstruct (named-list (:type list) :named) (value 17))
(defstruct (unnamed-float-vector (:type (vector single-float)) (:predicate nil))
  (value 1.5 :type single-float))
(print (let ((object (make-named-symbol-vector)))
         (list (named-symbol-vector-p object) (named-symbol-vector-value object))))
(print (let ((object (make-named-list)))
         (list (named-list-p object) (named-list-value object))))
(print (unnamed-float-vector-value (make-unnamed-float-vector)))
