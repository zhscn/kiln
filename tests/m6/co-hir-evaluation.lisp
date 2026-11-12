(defvar *hir-special* :outer)
(defun hir-read-special () (symbol-value '*hir-special*))

(eval '(defmacro hir-special-expansion ()
         (let ((*hir-special* :inner))
           (list 'quote (list *hir-special* (hir-read-special))))))
(print (equal '(:inner :inner)
              (funcall (compile nil '(lambda () (hir-special-expansion))))))
(print (eq *hir-special* :outer))

(eval '(defmacro hir-progv-expansion ()
         (list 'quote
               (progv '(*hir-special*) nil
                 (list (boundp '*hir-special*)
                       (handler-case (symbol-value '*hir-special*)
                         (unbound-variable () :unbound)))))))
(print (equal '(nil :unbound)
              (funcall (compile nil '(lambda () (hir-progv-expansion))))))
(print (eq *hir-special* :outer))

(eval '(defmacro hir-unwind-expansion ()
         (list 'quote
               (catch 'done
                 (let ((*hir-special* :temporary))
                   (throw 'done (hir-read-special)))))))
(print (eq :temporary
           (funcall (compile nil '(lambda () (hir-unwind-expansion))))))
(print (eq *hir-special* :outer))

(eval '(defmacro hir-nested-expansion ()
         (macrolet ((outer (x) `(list ,x ,x)))
           (macrolet ((inner (&environment env)
                        (declare (ignore env))
                        '(outer :lexical)))
             (list 'quote (inner))))))
(print (equal '(:lexical :lexical)
              (funcall (compile nil '(lambda () (hir-nested-expansion))))))
