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
