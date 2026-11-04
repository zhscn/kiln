;;;; kiln's client of ctype (docs/10 §13). It replaces ctype's host.lisp
;;;; and runtime.lisp, which compute their answers with the host's
;;;; SUBTYPEP and classes when they are loaded.

(in-package #:ctype)

;;; ctype's BASIC method combination produces SURELY forms (trivalent
;;; logic: the first form whose second value is true decides).
(push (cons 'surely
            (lambda (form sub)
              (let ((closures (mapcar sub (rest form))))
                (lambda (arguments)
                  (dolist (closure closures (values nil nil))
                    (multiple-value-bind (value surety) (funcall closure arguments)
                      (when surety
                        (return (values value surety)))))))))
      clostrophilia::*effective-method-operators*)

(defclass kiln-client () ())

(defmethod most-positive-fixnum ((client kiln-client))
  cl:most-positive-fixnum)

(defmethod most-negative-fixnum ((client kiln-client))
  cl:most-negative-fixnum)

;;; Floats: single-float is a short float, double-float a long float.
(defmethod reduce-float-type ((client kiln-client) type)
  (ecase type
    ((short-float single-float) 'single-float)
    ((double-float long-float) 'double-float)))

(defmethod distinct-float-types ((client kiln-client))
  '(single-float double-float))

(defmethod distinct-zeroes-p ((client kiln-client) type)
  (declare (ignore type))
  t)

(defmethod range-kindp ((client kiln-client) object kind)
  (case kind
    (integer (integerp object))
    (ratio (kiln.kernel::ratiop object))
    ((short-float single-float) (kiln.kernel::single-float-p object))
    ((double-float long-float) (kiln.kernel::double-float-p object))
    (t nil)))

;;; There are no complexes yet; their parts would be of these types.
(defmethod upgraded-complex-part-type ((client kiln-client) specifier &optional env)
  (cond ((subctypep client (specifier-ctype client specifier env)
                    (specifier-ctype client 'single-float env))
         'single-float)
        ((subctypep client (specifier-ctype client specifier env)
                    (specifier-ctype client 'double-float env))
         'double-float)
        ((subctypep client (specifier-ctype client specifier env)
                    (specifier-ctype client 'rational env))
         'rational)
        (t 'real)))

;;; Arrays: so far, simple vectors of T and strings (of characters).
(defmethod upgraded-array-element-type ((client kiln-client) specifier &optional env)
  (if (and (not (eq specifier 'nil))
           (subctypep client (specifier-ctype client specifier env)
                      (specifier-ctype client 'character env)))
      'character
      't))

(defmethod simple-array-p ((client kiln-client) object)
  (or (simple-vector-p object) (stringp object)))

(defmethod complex-arrays-distinct-p ((client kiln-client))
  t)

(defmethod string-uaets ((client kiln-client))
  '(character))

(defmethod find-class ((client kiln-client) name &optional (errorp t) env)
  (declare (ignore env))
  (cl:find-class name errorp))

(defmethod subclassp ((client kiln-client) class1 class2)
  (if (member class2 (clostrophilia:class-precedence-list class1)) t nil))

(defmethod class-aliases ((client kiln-client))
  '())

;;; Characters are Unicode code points; base characters are those of
;;; Latin-1's lower half, as in the kernel's TYPEP.
(defmethod char-code-limit ((client kiln-client))
  #x110000)

(defmethod standard-charset-pairs ((client kiln-client))
  '((10 . 10) (32 . 126)))

(defmethod base-charset-pairs ((client kiln-client))
  '((0 . 127)))

(defmethod sfdefinition ((client kiln-client) name)
  (fdefinition name))

(defmethod typexpand ((client kiln-client) specifier environment)
  (kiln.kernel::typexpand specifier environment))
