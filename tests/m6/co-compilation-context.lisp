(let ((outer nil) (inner nil))
  (kiln.compiler::call-with-compilation-request
   :test nil
   (lambda (request)
     (setf outer request)
     (kiln.compiler::note-dependency :macro 'outer-request-macro)
     (let ((function (compile nil '(lambda (x) (+ x 1)))))
       (print (funcall function 7)))
     (kiln.compiler::call-with-compilation-request
      :nested nil
      (lambda (request)
        (setf inner request)
        (kiln.compiler::note-dependency :macro 'inner-request-macro))
      :dependencies :fresh)
     (print (equal (cdr kiln.compiler::*dependencies*) '((:macro outer-request-macro)))))
   :dependencies :fresh :outputs :fresh :fingerprint :fresh)
  (print (eq (kiln.compiler::compilation-request-parent inner) outer))
  (print (eq (kiln.compiler::compilation-request-state outer) :complete))
  (print (not (null (find :native-compile (kiln.compiler::compilation-request-children outer)
                         :key #'kiln.compiler::compilation-request-purpose)))))
(print (null kiln.compiler::*compilation-request*))
