(in-package #:kiln.compiler)

;;;; Multiple values.
;;;;
;;;; A function returns its primary value and the number of values; values
;;;; after the first are in ctx.values, which the next call overwrites. To
;;;; keep values across code that may call (cleanups, MULTIPLE-VALUE-PROG1,
;;;; collecting the arguments of MULTIPLE-VALUE-CALL), they are turned into
;;;; a list. Consing the list allocates, so while it runs ctx.values_live
;;;; makes the transfer area a GC root.

(defun values-word (i)
  "KIR operand for the address-relative load of value I (I >= 1, raw
variable or integer) in ctx.values."
  `(:load (:add :ctx (:shl ,i 3)) ,(- +ctx-values+ 8)))

(defun emit-push-values (v0 n acc)
  "Conses the values (V0, N) onto the list operand ACC, first value
first, so the result holds them in reverse order. Returns the new list."
  (let ((r (copy-to-var acc)))
    (if (eql n 1)
        (emit `(:set ,r ,(emit-cons v0 r)))
        (let ((i (new-var :raw))
              (some (new-block)) (head (new-block)) (body (new-block))
              (fin (new-block)) (done (new-block)))
          (br `(:eq ,n 0) done some)
          (start-block some)
          (emit `(:store :ctx ,+ctx-values-live+ (:sub ,n 1)))
          (emit `(:set ,r ,(emit-cons v0 r)))
          (emit `(:set ,i 1))
          (jump head)
          (start-block head)
          (br `(:lt ,i ,n) body fin)
          (start-block body)
          (let ((x (copy-to-var (values-word i))))
            (emit `(:set ,r ,(emit-cons x r))))
          (emit `(:set ,i (:add ,i 1)))
          (jump head)
          (start-block fin)
          (emit `(:store :ctx ,+ctx-values-live+ 0))
          (jump done)
          (start-block done)))
    r))

(defun emit-nreverse (list)
  "Reverses the proper list LIST in place. No allocation."
  (let ((prev (copy-to-var (nil-value))) (cur (copy-to-var list)) (next (new-var))
        (head (new-block)) (body (new-block)) (done (new-block)))
    (jump head)
    (start-block head)
    (br `(:eq ,cur ,(nil-value)) done body)
    (start-block body)
    (emit `(:set ,next (:load ,cur ,+cons-cdr+)))
    (emit `(:store ,cur ,+cons-cdr+ ,prev))
    (emit `(:set ,prev ,cur))
    (emit `(:set ,cur ,next))
    (jump head)
    (start-block done)
    prev))

(defun emit-values-to-list (v0 n)
  (emit-nreverse (emit-push-values v0 n (nil-value))))

(defun emit-list-to-values (list)
  "Makes the elements of the proper list LIST the current values.
Returns the primary value and the count. No allocation."
  (let ((v0 (copy-to-var (nil-value))) (n (new-var :raw)) (cur (copy-to-var list))
        (first-b (new-block)) (head (new-block)) (body (new-block)) (done (new-block)))
    (emit `(:set ,n 0))
    (br `(:eq ,cur ,(nil-value)) done first-b)
    (start-block first-b)
    (emit `(:set ,v0 (:load ,cur ,+cons-car+)))
    (emit `(:set ,cur (:load ,cur ,+cons-cdr+)))
    (emit `(:set ,n 1))
    (jump head)
    (start-block head)
    (br `(:eq ,cur ,(nil-value)) done body)
    (start-block body)
    (let ((bad (new-block)) (ok (new-block)))
      (br `(:gt ,n ,+values-max+) bad ok)
      (start-block bad)
      (emit-error +err-wrong-nargs+ `(:shl ,n ,+fixnum-shift+))
      (start-block ok))
    (emit `(:store (:add :ctx (:shl ,n 3)) ,(- +ctx-values+ 8) (:load ,cur ,+cons-car+)))
    (emit `(:set ,cur (:load ,cur ,+cons-cdr+)))
    (emit `(:set ,n (:add ,n 1)))
    (jump head)
    (start-block done)
    (values v0 n)))

(defun emit-save-values (v0 n)
  "Saves the values (V0, N) in an obj variable: V0 itself for one value,
else a list."
  (if (eql n 1)
      (copy-to-var v0)
      (let ((saved (new-var)) (one (new-block)) (many (new-block)) (join (new-block)))
        (br `(:eq ,n 1) one many)
        (start-block one)
        (emit `(:set ,saved ,v0))
        (jump join)
        (start-block many)
        (emit `(:set ,saved ,(emit-values-to-list v0 n)))
        (jump join)
        (start-block join)
        saved)))

(defun emit-restore-values (saved n)
  "Inverse of EMIT-SAVE-VALUES; N is the count it was given."
  (if (eql n 1)
      (values saved 1)
      (let ((v0 (new-var)) (rn (new-var :raw))
            (one (new-block)) (many (new-block)) (join (new-block)))
        (br `(:eq ,n 1) one many)
        (start-block one)
        (set-mv v0 rn saved 1)
        (jump join)
        (start-block many)
        (multiple-value-call #'set-mv v0 rn (emit-list-to-values saved))
        (jump join)
        (start-block join)
        (values v0 rn))))

(defun emit-apply (f list)
  "Calls the function object F (already checked) with the elements of the
proper list LIST as arguments. Returns the primary value and the count."
  (let ((args (loop repeat +reg-args+ collect (copy-to-var 0)))
        (cur (copy-to-var list)) (i (new-var :raw))
        (head (new-block)) (body (new-block)) (done (new-block)))
    (emit `(:set ,i 0))
    (jump head)
    (start-block head)
    (br `(:eq ,cur ,(nil-value)) done body)
    (start-block body)
    (let ((x `(:load ,cur ,+cons-car+))
          (bad (new-block)) (stack (new-block)) (next (new-block)))
      (br `(:ge ,i ,(+ +reg-args+ +values-max+)) bad stack)
      (start-block bad)
      (emit-error +err-wrong-nargs+ `(:shl ,i ,+fixnum-shift+))
      (start-block stack)
      ;; Registers for the first arguments, the transfer area for the rest.
      (loop for a in args
            for k from 0
            do (let ((this (new-block)) (other (new-block)))
                 (br `(:eq ,i ,k) this other)
                 (start-block this)
                 (emit `(:set ,a ,x))
                 (jump next)
                 (start-block other)))
      (emit `(:store (:add :ctx (:shl ,i 3)) ,(- +ctx-values+ (* 8 +reg-args+)) ,x))
      (jump next)
      (start-block next))
    (emit `(:set ,cur (:load ,cur ,+cons-cdr+)))
    (emit `(:set ,i (:add ,i 1)))
    (jump head)
    (start-block done)
    ;; No safepoint between filling the transfer area and the call.
    (let ((v0 (new-var)) (nv (new-var :raw))
          (entry (copy-to-var `(:load ,f ,+fobj-entry+) :raw)))
      (emit `(:call-lisp ,v0 ,nv ,entry (:ctx ,f ,i ,@args) ,(handler)))
      (values v0 nv))))

(define-mv-lowering ico:multiple-value-prog1-ast (ast)
  (multiple-value-bind (v n) (lower-mv (ico:values-ast ast))
    (let ((saved (emit-save-values v n)))
      (lower-progn (ico:form-asts ast))
      (emit-restore-values saved n))))

(define-mv-lowering ico:multiple-value-call-ast (ast)
  (let ((f (copy-to-var (lower (ico:function-ast ast))))
        (acc (nil-value)))
    (dolist (form (ico:form-asts ast))
      (multiple-value-bind (v n) (lower-mv form)
        (setf acc (emit-push-values v n acc))))
    (let ((list (emit-nreverse acc)))
      (emit-apply (emit-function-designator f) list))))

(defun emit-rest-list (args start)
  "In a function entry, before any safepoint: returns a list of the
arguments from index START to nargs - 1. ARGS are obj variables holding
the register arguments. Arguments beyond them are still in the transfer
area, which stays a GC root while the list is consed."
  (let ((list (copy-to-var (nil-value))) (i (new-var :raw))
        (head (new-block)) (body (new-block)) (done (new-block)))
    (emit `(:store :ctx ,+ctx-values-live+
                   (:select (:gt :nargs ,+reg-args+) (:sub :nargs ,+reg-args+) 0)))
    (emit `(:set ,i :nargs))
    (jump head)
    (start-block head)
    (br `(:gt ,i ,start) body done)
    (start-block body)
    (emit `(:set ,i (:sub ,i 1)))
    (let ((x (new-var)) (join (new-block)))
      ;; x = argument i
      (loop for a in args
            for k from 0
            do (let ((this (new-block)) (other (new-block)))
                 (br `(:eq ,i ,k) this other)
                 (start-block this)
                 (emit `(:set ,x ,a))
                 (jump join)
                 (start-block other)))
      (emit `(:set ,x (:load (:add :ctx (:shl ,i 3)) ,(- +ctx-values+ (* 8 +reg-args+)))))
      (jump join)
      (start-block join)
      (emit `(:set ,list ,(emit-cons x list))))
    (jump head)
    (start-block done)
    (emit `(:store :ctx ,+ctx-values-live+ 0))
    list))
