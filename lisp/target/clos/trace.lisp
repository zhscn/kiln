;;;; Function tracing follows definitions and generic function dispatch updates.

(in-package #:kiln.kernel)

;;; Records are #(name target generic-function wrapper). Aliases of one
;;; generic function share a record because they share its callable entry.
(defvar *traced-functions* nil)
(defvar *trace-depth* 0)
(defvar *trace-internal* nil)

(defun trace-instance-record (instance)
  (dolist (binding *traced-functions*)
    (when (eq instance (svref (cdr binding) 2))
      (return (cdr binding)))))

(defun update-trace-hooks ()
  (setf *trace-definition-hook*
        (and *traced-functions* #'refresh-traced-definition)
        clostrophilia::*funcallable-instance-function-hook*
        (and (some (lambda (binding) (svref (cdr binding) 2)) *traced-functions*)
             #'refresh-traced-instance)))

(defun refresh-traced-instance (instance function)
  (let* ((*trace-internal* t)
         (record (trace-instance-record instance)))
    (if record
        (progn
          (unless (eq function (svref record 3))
            (setf (svref record 1) function))
          (svref record 3))
        function)))

(defun invoke-traced-function (record arguments)
  (if *trace-internal*
      (apply (svref record 1) arguments)
      (let ((*trace-depth* (1+ *trace-depth*))
            (completed nil))
        (let ((*trace-internal* t))
          (format *trace-output* "~&~D: (~S~{ ~S~})~%"
                  *trace-depth* (svref record 0) arguments))
        (unwind-protect
             (let ((results (multiple-value-list (apply (svref record 1) arguments))))
               (setf completed t)
               (let ((*trace-internal* t))
                 (format *trace-output* "~&~D: ~S returned~{ ~S~}~%"
                         *trace-depth* (svref record 0) results))
               (values-list results))
          (unless completed
            (let ((*trace-internal* t))
              (format *trace-output* "~&~D: ~S exited nonlocally~%"
                      *trace-depth* (svref record 0))))))))

(defun untrace-function-name (name &optional warnp)
  (let ((binding (assoc name *traced-functions* :test #'equal)))
    (if (null binding)
        (when warnp (warn "Function is not traced: ~S" name))
        (let* ((record (cdr binding))
               (instance (svref record 2)))
          (setf *traced-functions* (remove binding *traced-functions* :test #'eq))
          (unless (find record *traced-functions* :key #'cdr :test #'eq)
            (if instance
                (kiln.sys:%primop :set-funcallable-instance-function instance (svref record 1))
                (when (and (fboundp name) (eq (fdefinition name) (svref record 3)))
                  (setf (fdefinition name) (svref record 1)))))
          (update-trace-hooks)))))

(defun trace-function-name (name)
  (cond ((assoc name *traced-functions* :test #'equal)
         (warn "Function is already traced: ~S" name)
         name)
        ((or (not (fboundp name))
             (and (symbolp name) (or (macro-function name) (special-operator-p name))))
         (warn "Cannot trace undefined function or macro ~S" name)
         nil)
        (t
         (let* ((function (fdefinition name))
                (instance (and (typep function 'generic-function) function))
                (record (or (and instance (trace-instance-record instance))
                            (vector (copy-tree name)
                                    (if instance
                                        (kiln.sys:%primop :funcallable-instance-function instance)
                                        function)
                                    instance nil))))
           (unless (svref record 3)
             (let ((invoke #'invoke-traced-function))
               (setf (svref record 3)
                     (lambda (&rest arguments) (funcall invoke record arguments)))))
           (push (cons (copy-tree name) record) *traced-functions*)
           (update-trace-hooks)
           (if instance
               (kiln.sys:%primop :set-funcallable-instance-function instance (svref record 3))
               (setf (fdefinition name) (svref record 3)))
           name))))

(defun refresh-traced-definition (name)
  (let* ((*trace-internal* t)
         (binding (assoc name *traced-functions* :test #'equal)))
    (when binding
      (let ((record (cdr binding)))
        (unless (and (fboundp name)
                     (eq (fdefinition name) (or (svref record 2) (svref record 3))))
          (untrace-function-name name)
          (when (fboundp name) (trace-function-name name)))))))

(defun trace-function-names (names)
  (let ((*trace-internal* t))
    (if names
        (loop for name in names
              when (trace-function-name name) collect (copy-tree name))
        (mapcar (lambda (binding) (copy-tree (car binding))) *traced-functions*))))

(defun untrace-function-names (names)
  (let ((*trace-internal* t))
    (dolist (name (or names (mapcar #'car *traced-functions*)))
      (untrace-function-name name t))
    t))

(defmacro trace (&rest names)
  (dolist (name names)
    (unless (or (symbolp name)
                (and (consp name) (eq (first name) 'setf)
                     (consp (rest name)) (symbolp (second name)) (null (cddr name))))
      (error 'program-error)))
  `(trace-function-names ',names))

(defmacro untrace (&rest names)
  (dolist (name names)
    (unless (or (symbolp name)
                (and (consp name) (eq (first name) 'setf)
                     (consp (rest name)) (symbolp (second name)) (null (cddr name))))
      (error 'program-error)))
  `(untrace-function-names ',names))
