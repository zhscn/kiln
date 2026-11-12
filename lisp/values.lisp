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
  "Operand for value I (I >= 1, raw variable or integer) in the transfer area."
  `(:secondary-value-ref ,i))

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
          (emit `(:transfer-roots (:sub ,n 1)))
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
          (emit `(:transfer-roots 0))
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
    (emit `(:set ,next (:field-load ,kiln.kir::+packet-field-cons-cdr+ ,cur)))
    (emit `(:field-store ,kiln.kir::+packet-field-cons-cdr+ ,cur ,prev))
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
    (emit `(:set ,v0 (:field-load ,kiln.kir::+packet-field-cons-car+ ,cur)))
    (emit `(:set ,cur (:field-load ,kiln.kir::+packet-field-cons-cdr+ ,cur)))
    (emit `(:set ,n 1))
    (jump head)
    (start-block head)
    (br `(:eq ,cur ,(nil-value)) done body)
    (start-block body)
    (let ((bad (new-block)) (ok (new-block)))
      (br `(:gt ,n ,kiln.kir::+backend-values-max+) bad ok)
      (start-block bad)
      (emit-error +err-wrong-nargs+ `(:fixnum-tag ,n))
      (start-block ok))
    (emit `(:secondary-value-set ,n (:field-load ,kiln.kir::+packet-field-cons-car+ ,cur)))
    (emit `(:set ,cur (:field-load ,kiln.kir::+packet-field-cons-cdr+ ,cur)))
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
  (let ((args (loop repeat kiln.kir::+backend-reg-args+ collect (copy-to-var 0)))
        (cur (copy-to-var list)) (i (new-var :raw))
        (head (new-block)) (body (new-block)) (done (new-block)))
    (emit `(:set ,i 0))
    (jump head)
    (start-block head)
    (br `(:eq ,cur ,(nil-value)) done body)
    (start-block body)
    (let ((x `(:field-load ,kiln.kir::+packet-field-cons-car+ ,cur))
          (bad (new-block)) (stack (new-block)) (next (new-block)))
      (br `(:ge ,i ,(+ kiln.kir::+backend-reg-args+ kiln.kir::+backend-values-max+)) bad stack)
      (start-block bad)
      (emit-error +err-wrong-nargs+ `(:fixnum-tag ,i))
      (start-block stack)
      (emit `(:arg-write ,i ,x ,args))
      (jump next)
      (start-block next))
    (emit `(:set ,cur (:field-load ,kiln.kir::+packet-field-cons-cdr+ ,cur)))
    (emit `(:set ,i (:add ,i 1)))
    (jump head)
    (start-block done)
    ;; No safepoint between filling the transfer area and the call.
    (let ((v0 (new-var)) (nv (new-var :raw)))
      (emit `(:invoke-prepared ,v0 ,nv ,f ,i ,args ,(handler)))
      (values v0 nv))))


(defun emit-rest-list (args start &optional stack-slots)
  "In a function entry, before any safepoint: returns a list of the
arguments from index START to nargs - 1. ARGS are obj variables holding
the register arguments. Arguments beyond them are still in the transfer
area, which stays a GC root while the list is consed. STACK-SLOTS, when
provided, are initialized cons slots with registered reference fields;
use them only when the entire list fits, otherwise allocate on the heap."
  (let ((list (copy-to-var (nil-value))) (i (new-var :raw))
        (head (new-block)) (body (new-block)) (done (new-block)))
    (emit `(:transfer-roots
                   (:select (:gt :nargs ,kiln.kir::+backend-reg-args+) (:sub :nargs ,kiln.kir::+backend-reg-args+) 0)))
    (emit `(:set ,i :nargs))
    (jump head)
    (start-block head)
    (br `(:gt ,i ,start) body done)
    (start-block body)
    (emit `(:set ,i (:sub ,i 1)))
    (let ((x (new-var)))
      (emit `(:arg-read ,x ,i ,args))
      (if stack-slots
          (let ((stack (new-block)) (heap (new-block)) (next (new-block)))
            (br `(:le :nargs ,(+ start (length stack-slots))) stack heap)
            (start-block stack)
            (let ((address
                    (loop for slot in stack-slots for index from start
                          for address = `(:slot ,slot) then
                            `(:select (:eq ,i ,index) (:slot ,slot) ,address)
                          finally (return address))))
              (let ((p (copy-to-var address :raw)))
                (emit `(:stack-cons ,list ,p ,x ,list))))
            (jump next)
            (start-block heap)
            (emit `(:set ,list ,(emit-cons x list)))
            (jump next)
            (start-block next))
          (emit `(:set ,list ,(emit-cons x list)))))
    (jump head)
    (start-block done)
    (emit `(:transfer-roots 0))
    list))
