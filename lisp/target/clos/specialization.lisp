;;;; Call-site constructors, with optional native promotion.
(in-package #:clostrophilia)

;;; Calls through one constructor object before its code is generated. Compiling takes a few milliseconds,
;;; and what it saves is tens of nanoseconds a call: below a thousand calls
;;; it does not pay.
(defvar *specialization-threshold* 1000)
(defvar *specialization-compiler* nil)
(defvar *generating-specialization* nil)
(defvar *generated-constructors* 0)
(defvar *specialization-last-error* nil)
;;; The constructor objects of each class: a list of entries, one per
;;; initarg shape. They are kept as long as the class is, so that a shape
;;; promoted once stays promoted for every call site that uses it.
(defvar *constructor-objects* (make-hash-table :test 'eq))

(defun native-specialization-ready-p ()
  (declare (special kiln.kernel::*compile-function*))
  (and *specialization-compiler* (not *generating-specialization*)
       (boundp 'kiln.kernel::*compile-function*) kiln.kernel::*compile-function*))

(defun compile-specialization (form)
  (when (native-specialization-ready-p)
    (let ((*generating-specialization* t))
      (handler-case (funcall *specialization-compiler* form)
        ;; Compilation is optional; an unsuccessful promotion keeps its closure.
        (error (condition)
          (let* ((*print-level* 4) (*print-length* 8)
                 (message (princ-to-string condition)))
            (setf *specialization-last-error* (subseq message 0 (min 512 (length message)))))
          nil)))))

;;; Constructor descriptor: class, layout stamp, class change version,
;;; initialization version, constant keyword names, callable, hit count,
;;; promotion state (NIL, T for native code, or :FAILED until the
;;; assumptions change). The stamp changes when the class is finalized
;;; again, the class change version when its name goes to another class.
(defun constructor-initargs (keys values)
  (loop for key in keys for value in values append (list key value)))

(defmacro define-constructor-factory ()
  (labels ((cases (fast-p)
             `(case (length keys)
                ,@(loop for n from 0 to 6
                        for parameters = (loop repeat n collect (make-symbol "VALUE"))
                        for arguments = `(list ,@(loop for parameter in parameters for i from 0
                                                       append `((nth ,i keys) ,parameter)))
                        collect
                        `(,n (lambda ,parameters
                               ,(if fast-p `(construct-instance class ,arguments)
                                    `(apply #'make-instance class ,arguments)))))
                (otherwise
                 (lambda (&rest values)
                   ,(if fast-p
                        '(construct-instance class (constructor-initargs keys values))
                        '(apply #'make-instance class (constructor-initargs keys values))))))))
    `(defun make-constructor-function (class keys fast-p)
       (if fast-p ,(cases t) ,(cases nil)))))
(define-constructor-factory)

(defun make-call-site-constructor (class keys)
  (let ((entry (vector class (%slot class '%unique-number) *class-change-version*
                       (construction-version) keys nil 0 nil)))
    (setf (svref entry 5)
          (make-constructor-function class keys (cached-fast-construction-p class)))
    ;; Deciding may finalize the class, which gives it its layout's stamp.
    (setf (svref entry 1) (%slot class '%unique-number))
    entry))

(defun constructor-entry-valid-p (entry)
  (and (eql (svref entry 1) (%slot (svref entry 0) '%unique-number))
       (eql (svref entry 2) *class-change-version*)
       (eql (svref entry 3) (construction-version))))

(defun shared-call-site-constructor (class keys)
  (let* ((entries (gethash class *constructor-objects*))
         (entry (find keys entries :key (lambda (entry) (svref entry 4)) :test #'equal)))
    (if (and entry (constructor-entry-valid-p entry))
        entry
        (let ((new (make-call-site-constructor class keys)))
          (setf (gethash class *constructor-objects*)
                (cons new (remove entry entries :test #'eq)))
          new))))

(defun generated-constructor-form (entry)
  (let* ((class (svref entry 0)) (keys (svref entry 4))
         (parameters (loop for key in keys collect (make-symbol "INITARG")))
         (available (mapcar #'cons keys parameters))
         (bindings '()) (stores '()) (instance (make-symbol "INSTANCE")))
    ;; Defaults run in order, before allocation, including defaults unused by slots.
    (dolist (default (%slot class '%default-initargs))
      (unless (assoc (first default) available)
        (let ((variable (make-symbol "DEFAULT")))
          (push `(,variable (funcall ',(third default))) bindings)
          (setf available (append available (list (cons (first default) variable)))))))
    (dolist (slot (class-slots class))
      (let* ((location (slot-definition-location slot))
             (argument (loop for pair in available
                             when (member (car pair) (slot-definition-initargs slot))
                               return pair))
             (initfunction (slot-definition-initfunction slot))
             (place (if (consp location) `(car ',location)
                        `(standard-instance-access ,instance ,location))))
        (cond (argument (push `(setf ,place ,(cdr argument)) stores))
              (initfunction
               (push `(when (eq ,place +unbound-slot-value+)
                        (setf ,place (funcall ',initfunction))) stores)))))
    `(lambda ,parameters
       (let* (,@(reverse bindings)
              (,instance (allocate-general-instance ',class ,(+ 2 (%slot class '%instance-size)))))
         (setf (slot-value-using-location+1 ,instance -2) ,(svref entry 1)
               (slot-value-using-location+1 ,instance -1) ',(class-slots class))
         ,@(reverse stores)
         ,instance))))

(defun kiln.kernel::%constructor-target (cache class-name keys)
  (let ((entry (car cache)))
    (unless (and entry (constructor-entry-valid-p entry))
      (setf entry (shared-call-site-constructor (find-class class-name) keys)
            (car cache) entry))
    (unless (svref entry 7)
      (incf (svref entry 6))
      (when (and (>= (svref entry 6) *specialization-threshold*)
                 (native-specialization-ready-p)
                 (cached-fast-construction-p (svref entry 0)))
        (let ((function (compile-specialization (generated-constructor-form entry))))
          ;; Promotion can run user code through compiler protocols.
          (when (and function (constructor-entry-valid-p entry))
            (setf (svref entry 5) function (svref entry 7) t)
            (incf *generated-constructors*))
          (unless function (setf (svref entry 7) :failed))
          (unless (constructor-entry-valid-p entry)
            (setf (car cache) nil)
            (return-from kiln.kernel::%constructor-target
              (kiln.kernel::%constructor-target cache class-name keys))))))
    (svref entry 5)))
