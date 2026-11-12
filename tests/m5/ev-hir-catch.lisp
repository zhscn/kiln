;; Native throws into HIR catches preserve multiple values and cleanup.
(defun native-throw-values (x)
  (throw 'hir-tag (values x :second)))
(print (multiple-value-list (eval '(catch 'hir-tag (native-throw-values :first)))))
(print (eval '(catch 'hir-tag :normal)))
(print (multiple-value-list
        (eval '(catch 'hir-tag
                 (unwind-protect (native-throw-values :protected)
                   (eval '(values :cleanup :values)))))))
;; A long body selects the catch instruction with a 16-bit destination.
(print (multiple-value-list
        (eval `(let ((n 0))
                 (catch 'hir-tag
                   ,@(loop repeat 100 collect '(incf n))
                   (native-throw-values n))))))
