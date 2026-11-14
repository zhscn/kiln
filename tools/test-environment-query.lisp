;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(call-with-compilation-request
 :query-test nil
 (lambda (request)
   (declare (ignore request))
   (let* ((events nil)
         (*dependency-query-hook* (lambda (key) (declare (ignore key)) (push :prepare events))))
     (with-environment-query (result :type 'missing-query-type)
       (push :lookup events) nil)
     (assert (equal events '(:lookup :prepare)))
     (assert (member '(:type missing-query-type) (cdr *dependencies*) :test #'equal))))
 :dependencies :fresh)

(let ((session (make-session)))
  (call-with-front-end
   session
   (lambda ()
     (evaluate-at-compile-time *client* '(defun known-query-function () 1) *environment*)
     (let ((*dependencies* (list :dependencies)))
       (trucler:describe-function *client* *environment* 'known-query-function)
       (trucler:describe-function *client* *environment* 'absent-query-function)
       (assert (member '(:macro known-query-function) (cdr *dependencies*) :test #'equal))
       (assert (member '(:macro absent-query-function) (cdr *dependencies*) :test #'equal)))
     (let ((*dependencies* (list :dependencies))
           (environment (hir-env *environment* :funcs (list (cons 'local-query-function (make-hir-fun))))))
       (trucler:describe-function *client* environment 'local-query-function)
       (assert (null (cdr *dependencies*)))))))

(let* ((*source-file* "query-origin") (*toplevel-source* nil)
       (forms (front-end-forms
               '((eval-when (:compile-toplevel)
                   (defmacro origin-outer (x) (list 'origin-inner x))
                   (defmacro origin-inner (x) (list 'list x)))
                 (defun origin-target (x) (origin-outer x)))))
       (found nil))
  (labels ((walk-function (function) (hir-map-function #'walk function))
           (walk (node)
             (let ((origin (hir-node-origin node)))
               (when (and (eq (getf origin :operator) 'origin-inner)
                          (eq (getf (getf origin :parent) :operator) 'origin-outer))
                 (setf found t)))
             (let ((child (hir-own-function node))) (when child (walk-function child)))
             (when (= (hir-node-kind node) 13)
               (loop for child across (hir-node-a node) do (walk-function child)))
             (hir-map-children #'walk node)))
    (dolist (form forms) (walk-function (toplevel-form-ast form))))
  (assert found))

(format t "Environment queries and expansion provenance passed.~%")
