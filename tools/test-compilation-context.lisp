;;;; Run after tools/env.lisp and (ql:quickload "kiln").
(in-package #:kiln.compiler)

(let ((parent nil) (child nil) (failed nil))
  (call-with-compilation-request
   :test nil
   (lambda (request)
     (setf parent request)
     (note-dependency :macro 'outer-query)
     (call-with-compilation-request
      :nested nil
      (lambda (request)
        (setf child request)
        (note-dependency :macro 'inner-query))
      :dependencies :fresh)
     (assert (equal (cdr *dependencies*) '((:macro outer-query))))
     (handler-case
         (call-with-compilation-request :failure nil
           (lambda (request) (setf failed request) (error "Expected request failure")))
       (error () nil))
     (assert (eq *compilation-request* parent)))
   :dependencies :fresh)
  (assert (eq (compilation-request-parent child) parent))
  (assert (equal (compilation-request-children parent) (list child failed)))
  (assert (eq (compilation-request-state parent) :complete))
  (assert (eq (compilation-request-state child) :complete))
  (assert (eq (compilation-request-state failed) :failed))
  (assert (equal (cdr (compilation-request-dependencies child)) '((:macro inner-query)))))
(assert (null *compilation-request*))
(format t "Compilation request ownership passed.~%")
