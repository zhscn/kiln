;; Native throws into bytecode catches must transfer all values to the VM.
(defun native-throw-values (x)
  (throw 'bytecode-tag (values x :second)))
(print (multiple-value-list (eval '(catch 'bytecode-tag (native-throw-values :first)))))
(print (eval '(catch 'bytecode-tag :normal)))
(print (multiple-value-list
        (eval '(catch 'bytecode-tag
                 (unwind-protect (native-throw-values :protected)
                   (eval '(values :cleanup :values)))))))
;; A long body selects the catch instruction with a 16-bit destination.
(print (multiple-value-list
        (eval `(let ((n 0))
                 (catch 'bytecode-tag
                   ,@(loop repeat 100 collect '(incf n))
                   (native-throw-values n))))))
