;;;; Run after tools/env.lisp and (ql:quickload "kiln"). Requires kernel.lir
;;;; and clos.lir from tools/test.sh, plus target/debug/kiln-cg.
(in-package #:kiln.compiler)

(let* ((root (asdf:system-source-directory "kiln"))
       (output (merge-pathnames "build/mir-test/host.lir" root))
       (session (make-session))
       (form '(progn (print
               (funcall (lambda (a b)
                          (declare (optimize (speed 0)))
                          (let ((i 0))
                            (tagbody
                             again
                               (if (= i 3) (go done))
                               (let ((temp a)) (setq a b b temp))
                               (setq i (1+ i))
                               (go again)
                             done)
                            (list a b i)))
                        11 22))
                      (print (list :unreachable
                                   (funcall (lambda (x)
                                              (declare (optimize (speed 0)))
                                              (tagbody (go done) skipped (setq x (1+ x)) done)
                                              x) 5))))))
  (ensure-directories-exist output)
  (kiln::write-module (compile-module (front-end-forms (list form) session) "mir-host"
                                     :session session :pipeline :mir)
                      output)
  (let ((text (uiop:run-program
               (mapcar #'namestring
                       (list (merge-pathnames "target/debug/kiln-cg" root)
                             #P"jit" (merge-pathnames "build/test/kernel.lir" root)
                             (merge-pathnames "build/test/clos.lir" root) output))
               :output :string :error-output :string)))
    (assert (and (search "(22 11 3)" text) (search "(:UNREACHABLE 5)" text))
            () "Unexpected host MIR execution output: ~S" text)))
(format t "Host MIR to binary LIR execution passed.~%")

(let* ((root (asdf:system-source-directory "kiln"))
       (output (merge-pathnames "build/mir-test/values.lir" root))
       (session (make-session))
       (form '(locally (declare (optimize (speed 0)))
                (print (multiple-value-bind (a b c) (values 1 :good)
                         (identity 99) (list a b c)))
                (print (multiple-value-bind (a b) (values) (list a b))))))
  (ensure-directories-exist output)
  (kiln::write-module (compile-module (front-end-forms (list form) session) "mir-values"
                                     :session session :pipeline :mir) output)
  (let ((text (uiop:run-program
               (mapcar #'namestring
                       (list (merge-pathnames "target/debug/kiln-cg" root) #P"jit"
                             (merge-pathnames "build/test/kernel.lir" root)
                             (merge-pathnames "build/test/clos.lir" root) output))
               :output :string :error-output :string)))
    (assert (and (search "(1 :GOOD NIL)" text) (search "(NIL NIL)" text))
            () "Unexpected MIR multiple-value output: ~S" text)))
(format t "Host MIR multiple-value binding execution passed.~%")

(let* ((root (asdf:system-source-directory "kiln"))
       (output (merge-pathnames "build/mir-test/value-call.lir" root))
       (session (make-session))
       (form '(locally (declare (optimize (speed 0)))
                (print (multiple-value-call #'list (values 1 2) (values) (values 3 4)))
                (print (multiple-value-call #'list)))))
  (ensure-directories-exist output)
  (kiln::write-module (compile-module (front-end-forms (list form) session) "mir-value-call"
                                     :session session :pipeline :mir) output)
  (let ((text (uiop:run-program
               (mapcar #'namestring
                       (list (merge-pathnames "target/debug/kiln-cg" root) #P"jit"
                             (merge-pathnames "build/test/kernel.lir" root)
                             (merge-pathnames "build/test/clos.lir" root) output))
               :output :string :error-output :string)))
    (assert (and (search "(1 2 3 4)" text) (search "NIL" text))
            () "Unexpected MIR multiple-value call output: ~S" text)))
(format t "Host MIR multiple-value call execution passed.~%")

(let* ((root (asdf:system-source-directory "kiln"))
       (output (merge-pathnames "build/mir-test/storage.lir" root))
       (session (make-session))
       (form '(let ((x (cons (list 1 2) nil)))
                (rplacd x x)
                (kiln.sys:%gc)
                (print (list :stack-gc (if (eq x (cdr x)) (car (car x)) 0))))))
  (ensure-directories-exist output)
  (kiln::write-module (compile-module (front-end-forms (list form) session) "mir-storage"
                                     :session session :pipeline :mir) output)
  (let ((dump (uiop:run-program (list (namestring (merge-pathnames "target/debug/kiln-cg" root))
                                     "dump" (namestring output)) :output :string)))
    (assert (search "(stack " dump) () "MIR did not select stack storage."))
  (let ((text (uiop:run-program
               (mapcar #'namestring
                       (list (merge-pathnames "target/debug/kiln-cg" root) #P"jit"
                             (merge-pathnames "build/test/kernel.lir" root)
                             (merge-pathnames "build/test/clos.lir" root) output))
               :output :string :error-output :string)))
    (assert (search "(:STACK-GC 1)" text) () "Unexpected MIR stack storage output: ~S" text)))
(format t "Host MIR stack cons GC execution passed.~%")

(let* ((root (asdf:system-source-directory "kiln"))
       (output (merge-pathnames "build/mir-test/borrow.lir" root))
       (session (make-session))
       (form '(flet ((reader (p) (kiln.sys:%gc) (car p)))
                (declare (notinline reader))
                (let ((x (cons (list 8) nil)))
                  (print (list :borrow-gc (if (eq x x) (reader x) nil)))))))
  (ensure-directories-exist output)
  (kiln::write-module (compile-module (front-end-forms (list form) session) "mir-borrow"
                                     :session session :pipeline :mir) output)
  (let ((dump (uiop:run-program (list (namestring (merge-pathnames "target/debug/kiln-cg" root))
                                     "dump" (namestring output)) :output :string)))
    (assert (search "(stack " dump) () "MIR did not select stack storage across the borrower."))
  (let ((text (uiop:run-program
               (mapcar #'namestring
                       (list (merge-pathnames "target/debug/kiln-cg" root) #P"jit"
                             (merge-pathnames "build/test/kernel.lir" root)
                             (merge-pathnames "build/test/clos.lir" root) output))
               :output :string :error-output :string)))
    (assert (search "(:BORROW-GC (8))" text) () "Unexpected MIR borrower output: ~S" text)))
(format t "Host MIR borrower stack GC execution passed.~%")

(let* ((root (asdf:system-source-directory "kiln"))
       (output (merge-pathnames "build/mir-test/optional.lir" root))
       (session (make-session))
       (form '(progn
                (print (funcall (lambda (a &optional (b a bp) (c (if bp 7 8)))
                                  (declare (optimize (speed 0))) (list a b bp c)) 1))
                (print (funcall (lambda (&optional (x 9 xp))
                                  (declare (optimize (speed 0))) (list x xp)) nil))
                (print (funcall (lambda ()
                                  (declare (optimize (speed 0)))
                                  (let ((n 0))
                                    (tagbody again (setq n (1+ n)) (if (< n 3) (go again)))
                                    n))))))
       (module (compile-module (front-end-forms (list form) session) "mir-optional" :session session :pipeline :mir))
       (program (kiln.kir::normalize-lir-module module)))
  (assert (some (lambda (function)
                  (and (eq (first function) :function) (search "kiln_mir_" (second function))
                       (some (lambda (part) (and (eq (first part) :block)
                                                (find :poll (cddr part) :key #'first))) (cddr function))))
                (cddr program)) () "MIR CFG blocks lost their poll operations.")
  (ensure-directories-exist output)
  (kiln::write-module module output)
  (let ((text (uiop:run-program
               (mapcar #'namestring
                       (list (merge-pathnames "target/debug/kiln-cg" root) #P"jit"
                             (merge-pathnames "build/test/kernel.lir" root)
                             (merge-pathnames "build/test/clos.lir" root) output))
               :output :string :error-output :string)))
    (assert (and (search "(1 1 NIL 8)" text) (search "(NIL T)" text))
            () "Unexpected MIR optional output: ~S" text)))
(format t "Host MIR optional entry and CFG poll execution passed.~%")

(let* ((root (asdf:system-source-directory "kiln"))
       (output (merge-pathnames "build/mir-test/rest.lir" root))
       (session (make-session))
       (form '(progn
                (print (funcall (lambda (a &optional (b (progn (kiln.sys:%gc) a)) &rest xs)
                                  (declare (optimize (speed 0))) (list a b xs)) 1))
                (print (funcall (lambda (a &optional b &rest xs)
                                  (declare (optimize (speed 0)))
                                  (kiln.sys:%gc) (list a b xs)) 1 nil 3 4 5 6))
                (print (funcall (lambda (&rest xs)
                                  (declare (optimize (speed 0))) (kiln.sys:%gc) xs) 7 8 9))))
       (module (compile-module (front-end-forms (list form) session) "mir-rest" :session session :pipeline :mir)))
  (ensure-directories-exist output)
  (kiln::write-module module output)
  (let ((text (uiop:run-program
               (mapcar #'namestring
                       (list (merge-pathnames "target/debug/kiln-cg" root) #P"jit"
                             (merge-pathnames "build/test/kernel.lir" root)
                             (merge-pathnames "build/test/clos.lir" root) output))
               :output :string :error-output :string)))
    (assert (and (search "(1 1 NIL)" text) (search "(1 NIL (3 4 5 6))" text) (search "(7 8 9)" text))
            () "Unexpected MIR rest output: ~S" text)))
(format t "Host MIR rest entry and GC execution passed.~%")
