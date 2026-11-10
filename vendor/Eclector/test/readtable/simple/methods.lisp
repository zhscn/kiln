(cl:in-package #:eclector.readtable.simple.test)

(in-suite :eclector.readtable.simple)

(test readtablep.smoke
  "Smoke test for the method on the READTABLEP protocol function."
  (is-false (eclector.readtable:readtablep 1))
  (is-true (eclector.readtable:readtablep
            (make-instance 'eclector.readtable.simple:readtable))))

(test ascii-syntax/mutation-and-copy
  "ASCII classifications follow mutations and copies into existing tables."
  (let ((from (make-instance 'eclector.readtable.simple:readtable))
        (to (eclector.readtable:copy-readtable eclector.reader:*readtable*)))
    (loop for code below 128
          for char = (code-char code)
          do (setf (eclector.readtable:syntax-type from char) :single-escape))
    (eclector.readtable:copy-readtable-into from to)
    (loop for code below 128
          for char = (code-char code)
          do (is (eq :single-escape (eclector.readtable:syntax-type to char)))
             (setf (eclector.readtable:syntax-type from char) :constituent)
             (is (eq :constituent (eclector.readtable:syntax-type from char)))
             (is (eq :single-escape (eclector.readtable:syntax-type to char))))
    (eclector.readtable:set-macro-character from #\? #'list t)
    (is (eq :non-terminating-macro (eclector.readtable:syntax-type from #\?)))
    (eclector.readtable:make-dispatch-macro-character from #\!)
    (is (eq :terminating-macro (eclector.readtable:syntax-type from #\!)))
    (eclector.readtable:copy-readtable-into from to)
    (is (eq :constituent (eclector.readtable:syntax-type to #\A)))
    (setf (eclector.readtable:syntax-type from #\λ) :whitespace)
    (is (eq :whitespace (eclector.readtable:syntax-type from #\λ)))))
