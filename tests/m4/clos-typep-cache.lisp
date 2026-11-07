;;; TYPEP answers that depend only on the class are cached by the class's
;;; stamp (class names, (OR ...), (AND ...), (NOT ...) of them): they must
;;; follow class redefinition, CHANGE-CLASS, (SETF FIND-CLASS) and DEFTYPE.

(defun show (x) (write-line (prin1-to-string x)))

(defclass tc-a () ())
(defclass tc-b () ())
(defclass tc-c (tc-a) ())
(defclass tc-d (tc-c tc-b) ())

;; Types not known at compile time, so that the call sites are generic.
(defvar *types* '(tc-a tc-b tc-c (or tc-a tc-b) (and tc-a tc-b) (not tc-a)
                  (or null tc-b) (or integer tc-c) (and tc-a (not tc-c))))

(defun row (object)
  (mapcar (lambda (type) (if (typep object type) 1 0)) *types*))

(defvar *a* (make-instance 'tc-a))
(defvar *c* (make-instance 'tc-c))
(defvar *d* (make-instance 'tc-d))
;; Twice: the second time from the cache.
(dotimes (i 2)
  (show (list (row *a*) (row *c*) (row *d*) (row nil) (row 5) (row "x"))))

;; Constant compound types and many classes through one call site.
(defun walkerish (object)
  (cond ((typep object '(or tc-b integer)) 'b-or-integer)
        ((typep object '(and tc-a (not tc-c))) 'just-a)
        ((typep object 'tc-c) 'c)
        (t 'other)))
(dotimes (i 2)
  (show (mapcar #'walkerish (list *a* *c* *d* 7 nil "s" 'sym))))

;; Types whose answer is not the class's: not cached.
(show (list (typep 3 '(or (integer 0 2) null)) (typep 1 '(or (integer 0 2) null))
            (typep :k '(or keyword tc-a)) (typep 'k '(or keyword tc-a))
            (typep "ab" '(or (string 2) tc-a)) (typep "abc" '(or (string 2) tc-a))
            (typep 4 '(or (satisfies evenp) tc-a)) (typep 5 '(or (satisfies evenp) tc-a))))

;; Redefinition: TC-C no longer under TC-A, now under TC-B. The existing
;; instances are obsolete (their stamp is the old one) and still get the
;; new class's answers; so do new instances and subclasses.
(defclass tc-c (tc-b) ())
(defvar *c2* (make-instance 'tc-c))
(show (list (row *c*) (row *c2*) (row *d*)))
(show (mapcar #'walkerish (list *a* *c* *c2* *d*)))
(defclass tc-c (tc-a) ())
(show (list (row *c*) (row *c2*) (row *d*)))

;; CHANGE-CLASS: the instance takes the new class's stamp.
(defvar *x* (make-instance 'tc-a))
(show (row *x*))
(change-class *x* 'tc-b)
(show (row *x*))
(change-class *x* 'tc-d)
(show (row *x*))

;; (SETF FIND-CLASS): a name for another class.
(setf (find-class 'tc-alias) (find-class 'tc-a))
(defvar *alias-types* '(tc-alias (or tc-alias null)))
(defun alias-row (object) (mapcar (lambda (type) (typep object type)) *alias-types*))
(show (list (alias-row *a*) (alias-row *c*) (alias-row (make-instance 'tc-b))))
(setf (find-class 'tc-alias) (find-class 'tc-b))
(show (list (alias-row *a*) (alias-row *c*) (alias-row (make-instance 'tc-b))))

;; DEFTYPE: a type defined in terms of classes, then defined again.
(deftype tc-either () '(or tc-b integer))
(defvar *either-types* '(tc-either (or tc-either null) (not tc-either)))
(defun either-row (object) (mapcar (lambda (type) (typep object type)) *either-types*))
(show (list (either-row *a*) (either-row 3) (either-row (make-instance 'tc-b))))
(deftype tc-either () '(or tc-a symbol))
(show (list (either-row *a*) (either-row 3) (either-row (make-instance 'tc-b))))

;; Generic functions, made after the caches are warm, are still
;; funcallable instances.
(defgeneric tc-twice (x))
(defmethod tc-twice ((x integer)) (* x 2))
(show (list (tc-twice 21) (functionp #'tc-twice) (typep #'tc-twice '(or generic-function null))
            (functionp (make-instance 'tc-a))))
