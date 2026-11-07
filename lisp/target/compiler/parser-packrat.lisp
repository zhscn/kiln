;;;; parser.packrat's system definition turns its bootstrap expression
;;;; parser off once the system is loaded (PERFORM LOAD-OP :AFTER in
;;;; parser.packrat.asd): expressions are then parsed by the meta-grammars.
;;;; The compiler module does the same after parser.packrat's files.
;;;; Without it, DEFRULE on kiln parsed (? x) as (* x nil 1) and
;;;; (<- (a b) ...) as a set of the variable (A B).

(setf parser.packrat.bootstrap::*bootstrapping* nil)
