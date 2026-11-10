;;;; Stepping conditions and restart-based control of instrumented calls.

(in-package #:kiln.kernel)

(defvar *step-enabled* nil)
(defvar *step-continued* nil)
(defvar *step-depth* 0)
(defvar *step-out-depth* nil)

(define-condition kiln.sys:step-form-condition (condition)
  ((form :initarg :form :reader kiln.sys:step-form)
   (args :initarg :args :reader kiln.sys:step-args)))
(define-condition kiln.sys:step-finished-condition (condition) ())

(defun default-stepper (condition)
  (let ((*print-circle* t) (*print-readably* nil) (*print-length* 10) (*print-level* 5))
    (format *query-io* "~&Step: ~S~%" (kiln.sys:step-form condition))
    (loop
      (format *query-io* "Into (I), next (N), out (O), continue (C)? ")
      (force-output *query-io*)
      (let* ((command (read *query-io* nil :continue))
             (name (and (symbolp command) (string-upcase (symbol-name command)))))
        (cond ((member name '("I" "S" "INTO") :test #'equal)
               (invoke-restart 'kiln.sys:step-into))
              ((member name '("N" "NEXT") :test #'equal)
               (invoke-restart 'kiln.sys:step-next))
              ((member name '("O" "OUT") :test #'equal)
               (invoke-restart 'kiln.sys:step-out))
              ((member name '("C" "Q" "CONTINUE") :test #'equal)
               (invoke-restart 'kiln.sys:step-continue))
              (t (format *query-io* "~&Choose I, N, O or C.~%")))))))

(defvar kiln.sys:*stepper-hook* 'default-stepper
  "Function called with each STEP-FORM-CONDITION; NIL leaves handling to SIGNAL handlers.")

(defun step-before (form &optional arguments)
  (when (and *step-out-depth* (<= *step-depth* *step-out-depth*))
    (setf *step-out-depth* nil))
  (if (and *step-enabled* (not *step-continued*) (null *step-out-depth*))
      (restart-case
          (let ((condition (make-condition 'kiln.sys:step-form-condition :form form :args arguments))
                (hook kiln.sys:*stepper-hook*)
                (*step-enabled* nil)
                (kiln.sys:*stepper-hook* nil))
            (signal condition)
            (when hook (funcall hook condition))
            :into)
        (kiln.sys:step-into () :report "Step into this call." :into)
        (kiln.sys:step-next () :report "Step over this call." :next)
        (kiln.sys:step-out () :report "Resume after the current instrumented call."
          (if (zerop *step-depth*)
              (setf *step-continued* t)
              (setf *step-out-depth* (1- *step-depth*)))
          :into)
        (kiln.sys:step-continue () :report "Continue without further stops."
          (setf *step-continued* t *step-out-depth* nil)
          :continue))
      :into))

(defun step-finished ()
  (let ((*step-enabled* nil)) (signal 'kiln.sys:step-finished-condition))
  (values))

(defmacro step (form)
  `(let ((*step-enabled* t) (*step-continued* nil) (*step-depth* 0) (*step-out-depth* nil))
     (multiple-value-prog1 (kiln.sys::%step-body ,form)
       (kiln.sys::%step-quiet (step-finished)))))
