(in-package #:kiln.compiler)

;;;; Multiple values.
;;;;
;;;; Values that must survive calls are saved through backend operations.
;;;; The backend owns the carrier, transfer-area access, and allocation roots.

(defun values-word (i)
  "Operand for value I (I >= 1, raw variable or integer) in the transfer area."
  `(:secondary-value-ref ,i))

(defun emit-push-values (v0 n acc)
  "Prepends the values to ACC in reverse order, preserving all values during allocation."
  (let ((result (new-var)))
    (emit `(:push-values ,result ,v0 ,n ,acc ,(handler)))
    result))

(defun emit-nreverse (list)
  "Reverses the proper list LIST in place. No allocation."
  (let ((prev (copy-to-var (nil-value))) (cur (copy-to-var list)) (next (new-var))
        (head (new-block)) (body (new-block)) (done (new-block)))
    (jump head)
    (start-block head)
    (br `(:eq ,cur ,(nil-value)) done body)
    (start-block body)
    (emit `(:set ,next (:field-load ,kiln.kir::+packet-field-cons-cdr+ ,cur)))
    (emit `(:field-store ,kiln.kir::+packet-field-cons-cdr+ ,cur ,prev))
    (emit `(:set ,prev ,cur))
    (emit `(:set ,cur ,next))
    (jump head)
    (start-block done)
    prev))

(defun emit-values-to-list (v0 n)
  (let ((result (new-var)))
    (emit `(:values-list ,result ,v0 ,n ,(handler)))
    result))

(defun emit-list-to-values (list)
  "Makes the proper list LIST the current values, checking the value limit."
  (let ((primary (new-var)) (count (new-var :raw)))
    (emit `(:list-values ,primary ,count ,list ,(handler)))
    (values primary count)))

(defun emit-save-values (v0 n)
  "Saves values in an opaque carrier; one known value needs only its object."
  (if (eql n 1)
      (copy-to-var v0)
      (let ((saved (new-var)))
        (emit `(:save-values ,saved ,v0 ,n ,(handler)))
        saved)))

(defun emit-restore-values (saved n)
  "Restores a saved carrier with its original value count."
  (if (eql n 1)
      (values saved 1)
      (let ((primary (new-var)) (count (new-var :raw)))
        (emit `(:restore-values ,primary ,count ,saved ,n ,(handler)))
        (values primary count))))

(defun emit-apply (f list &optional fixed)
  "Calls the checked function object F with FIXED followed by LIST's
elements. Returns the primary value and the count."
  (let ((f (copy-to-var f)) (list (copy-to-var list))
        (fixed (mapcar #'copy-to-var fixed))
        (v0 (new-var)) (nv (new-var :raw)))
    (emit `(:invoke-list ,v0 ,nv ,f ,fixed ,list ,(handler) ,@(call-loc)))
    (values v0 nv)))


(defun emit-rest-list (start &optional stack-slots)
  "Constructs the incoming argument suffix, using registered cons slots
when the complete suffix fits and heap storage otherwise."
  (let ((list (new-var)))
    (emit `(:rest-list ,list ,start ,stack-slots ,(handler)))
    list))
