;; Bodies of top-level MACROLET, SYMBOL-MACROLET and LOCALLY are top-level
;; forms: definitions inside them take effect at compile time.
(macrolet ((define-getter (name value) (list 'defun name '() value)))
  (define-getter get-one 1)
  (define-getter get-two 2))
(print (list (get-one) (get-two)))

(macrolet ((outer () ''outer))
  (macrolet ((inner () (list 'list (list 'outer) ''inner)))
    (print (inner))))

;; A macro defined inside MACROLET at top level is usable afterwards.
(macrolet ((make-macro (name) (list 'defmacro name '(x) '(list 'quote (list x x)))))
  (make-macro twice))
(print (twice a))

(symbol-macrolet ((answer 42))
  (defun get-answer () answer))
(print (get-answer))

(locally
  (defmacro thrice (x) (list 'quote (list x x x))))
(print (thrice b))
