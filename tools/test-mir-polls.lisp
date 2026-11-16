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

;; Every remaining cycle would permit unbounded execution without a poll.
;; Test the graph property directly, including an irreducible two-entry SCC.
(dolist (outgoing '(#((1) (2) (3) (1))
                    #((1) (1))
                    #((1 2) (3) (3) (1 2))
                    #((1) (2 4) (3) (2 1) nil)))
  (let* ((function (make-mir-function)) (blocks (mir-function-blocks function)))
    (loop for targets across outgoing for id from 0 do
      (hir-push (make-mir-block :id id :terminator
                  (make-mir-terminator :edges
                    (map 'simple-vector (lambda (target) (make-mir-edge :target target)) targets))) blocks))
    (let* ((polls (mir-loop-poll-blocks function))
           (remaining (map 'simple-vector
                           (lambda (block)
                             (unless (logbitp (mir-block-id block) polls)
                               (loop for edge across (mir-terminator-edges (mir-block-terminator block))
                                     unless (logbitp (mir-edge-target edge) polls)
                                       collect (mir-edge-target edge))))
                           (hir-vector blocks))))
      (dolist (component (mir-strong-components remaining))
        (assert (null (cdr component)))
        (assert (not (member (car component) (svref remaining (car component))))))
      (when (equalp outgoing #((1) (2) (3) (1)))
        (assert (= 1 (logcount polls)))))))
(format t "Selected poll blocks intersect every CFG cycle.~%")
