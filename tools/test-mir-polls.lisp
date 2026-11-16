;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(defun mir-poll-test-forms (body)
  (let* ((session (make-session))
         (module (compile-module (front-end-forms (list body) session)
                                 "poll-placement" :session session)))
    (remove-if-not (lambda (form) (and (stringp (second form))
                                       (search "kiln_mir_" (second form) :start2 0)))
                   (kiln.kir::kmodule-funcs module))))

(defun mir-poll-test-count (forms operation)
  (let ((count 0))
    (labels ((visit (node)
               (when (consp node)
                 (when (and (eq (first node) :poll) (eq (second node) operation)) (incf count))
                 (dolist (part node) (visit part)))))
      (visit forms))
    count))

;; Acyclic branches need only the function-entry check. Cycles, including
;; multiple-entry SCCs, must retain explicit safepoints in their blocks.
(let ((forms (mir-poll-test-forms
               '(lambda (x) (if x (if (car x) 1 2) 3)))))
  (assert (plusp (mir-poll-test-count forms :entry)))
  (assert (zerop (mir-poll-test-count forms :loop))))
(dolist (body '((lambda () (tagbody again (go again)))
                (lambda (x) (tagbody again (setq x (cdr x)) (if x (go again))) x)
                (lambda (x)
                  (tagbody (if x (go a) (go b))
                   a (setq x (cdr x)) (if x (go b)) (go done)
                   b (setq x (cdr x)) (if x (go a))
                   done)
                  x)))
  (assert (plusp (mir-poll-test-count (mir-poll-test-forms body) :loop))))
(format t "MIR safepoints cover loops and omit acyclic interior blocks.~%")
