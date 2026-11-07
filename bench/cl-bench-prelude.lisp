;;; kiln's harness for cl-bench (bench/README.md), before cl-bench's
;;; files: tools/bench.sh concatenates this file, the files of
;;; bench/cl-bench/files/, its tests.lisp and bench/cl-bench-driver.lisp
;;; into one program, which kiln (AOT) and SBCL run. It replaces
;;; cl-bench's support.lisp and cl-bench.lisp (ASDF, trivial-garbage, the
;;; report files): DEFBENCH collects the benchmarks.

(defpackage :cl-bench
  (:use :cl)
  (:export #:defbench #:*misc-dir*))

(in-package :cl-bench)

;;; tools/bench.sh replaces the directory.
(defparameter *misc-dir* (pathname "@MISC-DIR@"))

(defvar *benchmarks* '())

(defmacro defbench (name &key group function (runs 1) setup short long
                              disabled-for disabled-form)
  (declare (ignore long disabled-form))
  `(push (list :name ,(or short (string-downcase (string name)))
               :group ,group :function ,function :runs ,runs
               :setup ,setup :disabled-for ,disabled-for)
         *benchmarks*))
