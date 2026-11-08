;;; Mutation and retirement of assumptions, including callbacks that exit.
(defun show (x) (write-line (prin1-to-string x)))
(defun version (kind name) (kiln.sys:assumption-version kind name))

(defvar *events* 0)
(defvar *watcher* (lambda (names) (incf *events* (length names))))
(kiln.kernel::register-assumption-watcher :protocol *watcher*)
(defvar *token* (kiln.kernel::register-assumption-dependent
                 :protocol 'cancelled (lambda () (error "Cancelled callback ran"))))
(kiln.kernel::cancel-assumption-dependent *token*)
(kiln.kernel::cancel-assumption-dependent *token*)
(kiln.kernel::change-assumption :protocol 'cancelled)
(show (and (null (car *token*)) (null (cdr *token*)) (= *events* 1)))

;;; Both nonlocal exits from a batch and a failing dependent still notify.
(handler-case
    (kiln.kernel::defer-assumption-changes
     (lambda ()
       (kiln.kernel::change-assumption :protocol 'batch)
       (error "Batch failed")))
  (error () nil))
(show (= *events* 2))
(defvar *drained* nil)
(kiln.kernel::register-assumption-dependent
 :protocol 'failure (lambda () (setq *drained* t)))
(kiln.kernel::register-assumption-dependent
 :protocol 'failure (lambda () (error "Dependent failed")))
(handler-case (kiln.kernel::change-assumption :protocol 'failure) (error () nil))
(show (and *drained* (= *events* 3)))
(kiln.kernel::unregister-assumption-watcher :protocol *watcher*)
(kiln.kernel::change-assumption :protocol 'batch)
(show (= *events* 3))

;;; Reentrant changes from watchers are delivered, rather than deferred forever.
(defvar *inner-events* 0)
(defvar *inner-watcher* (lambda (names) (incf *inner-events* (length names))))
(defvar *outer-watcher* (lambda (names)
                         (declare (ignore names))
                         (kiln.kernel::change-assumption :inner 'inner)))
(kiln.kernel::register-assumption-watcher :inner *inner-watcher*)
(kiln.kernel::register-assumption-watcher :outer *outer-watcher*)
(kiln.kernel::change-assumption :outer 'outer)
(show (= *inner-events* 1))
(kiln.kernel::unregister-assumption-watcher :inner *inner-watcher*)
(kiln.kernel::unregister-assumption-watcher :outer *outer-watcher*)

;;; Retirement invalidates old guards and allows callbacks to register anew.
(defvar *old-cell* (kiln.kernel::assumption-cell :protocol 'retired))
(defvar *new-token* nil)
(kiln.kernel::register-assumption-dependent
 :protocol 'retired
 (lambda ()
   (setq *new-token* (kiln.kernel::register-assumption-dependent
                     :protocol 'retired (lambda () (setq *drained* :new))))))
(kiln.kernel::release-assumption :protocol 'retired)
(show (and (= (svref *old-cell* 0) 1)
           (not (eq *old-cell* (kiln.kernel::assumption-cell :protocol 'retired)))))
(kiln.kernel::change-assumption :protocol 'retired)
(show (eq *drained* :new))
(kiln.kernel::release-assumption :protocol 'retired)
(show (null (kiln.kernel::find-assumption-cell :protocol 'retired)))

;;; Actual function bindings, including independently allocated SETF names.
(defun binding-target () 1)
(defvar *function-version* (version :function 'binding-target))
(defun binding-target () 2)
(show (< *function-version* (version :function 'binding-target)))
(setq *function-version* (version :function 'binding-target))
(setf (symbol-function 'binding-target) (lambda () 3))
(show (< *function-version* (version :function 'binding-target)))
(setq *function-version* (version :function 'binding-target))
(fmakunbound 'binding-target)
(show (< *function-version* (version :function 'binding-target)))
(defvar *setf-cell* (kiln.kernel::assumption-cell :function (list 'setf 'binding-target)))
(setf (fdefinition (list 'setf 'binding-target)) (lambda (value x) (declare (ignore x)) value))
(show (= (svref *setf-cell* 0) 1))

;;; Direct finalization and reinitialization are mutation entry points too.
(defclass protocol-class () ((a :initform 1)))
(defvar *class* (find-class 'protocol-class))
(defvar *class-version* (version :class *class*))
;; A first finalization is not a change (no instance, so no cache, can
;; mention the class yet); finalizing again is.
(clostrophilia:finalize-inheritance *class*)
(show (= *class-version* (version :class *class*)))
(clostrophilia:finalize-inheritance *class*)
(show (< *class-version* (version :class *class*)))
(setq *class-version* (version :class *class*))
(reinitialize-instance *class* :documentation "Updated")
(show (and (< *class-version* (version :class *class*))
           (= (slot-value (make-instance 'protocol-class) 'a) 1)))

(defgeneric combined (x))
(defmethod combined ((x integer)) 1)
(defmethod combined ((x string)) 2)
(show (list (combined 1) (combined "s")))
(defvar *methods-version* (version :methods #'combined))
(reinitialize-instance #'combined :documentation "Updated")
(show (and (< *methods-version* (version :methods #'combined))
           (= (combined 1) 1) (= (combined "s") 2)))

;;; Changing precedence through ENSURE-GENERIC-FUNCTION discards warm methods.
(defgeneric precedence (x y))
(defmethod precedence ((x integer) y) (declare (ignore y)) :first)
(defmethod precedence (x (y integer)) (declare (ignore x)) :second)
(show (eq (precedence 1 2) :first))
(setq *methods-version* (version :methods #'precedence))
(ensure-generic-function 'precedence :lambda-list '(x y)
                         :argument-precedence-order '(y x))
(show (and (< *methods-version* (version :methods #'precedence))
           (eq (precedence 1 2) :second)
           (eq (precedence 1 "s") :first)
           (eq (precedence "s" 2) :second)))

;;; One observer's error does not suppress another observer's invalidation.
(defvar *observer-ran* nil)
(defvar *observer* (lambda (names) (declare (ignore names)) (setq *observer-ran* t)))
(defvar *failing-observer* (lambda (names) (declare (ignore names)) (error "Observer failed")))
(kiln.kernel::register-assumption-watcher :observer *observer*)
(kiln.kernel::register-assumption-watcher :observer *failing-observer*)
(handler-case (kiln.kernel::change-assumption :observer 'test) (error () nil))
(show *observer-ran*)
(kiln.kernel::unregister-assumption-watcher :observer *observer*)
(kiln.kernel::unregister-assumption-watcher :observer *failing-observer*)

;;; Retiring entries preserves probing chains and stable cells after growth.
(defvar *owners* (make-array 300))
(dotimes (i 300)
  (setf (svref *owners* i) (list i))
  (kiln.kernel::assumption-cell :owner (svref *owners* i)))
(dotimes (i 300)
  (when (evenp i) (kiln.kernel::release-assumption :owner (svref *owners* i))))
(show (loop for i below 300
            always (eq (not (null (kiln.kernel::find-assumption-cell :owner (svref *owners* i))))
                       (oddp i))))
(dotimes (i 300)
  (when (oddp i) (kiln.kernel::release-assumption :owner (svref *owners* i))))


;;; A new method combination changes a warmed effective method.
(define-method-combination collected () ((primary () :required t))
  `(list ,@(mapcar (lambda (method) `(call-method ,method)) primary)))
(defgeneric combination-target (x))
(defmethod combination-target ((x integer)) 1)
(defmethod combination-target ((x t)) 2)
(show (= (combination-target 1) 1))
(ensure-generic-function 'combination-target :method-combination '(collected))
(show (equal (combination-target 1) '(1 2)))

;;; An equivalent combination with its own identity must use the protocol.
(define-method-combination alternate-standard ()
  ((around (:around)) (before (:before)) (primary ()) (after (:after)))
  (let ((core `(multiple-value-prog1
                   (progn ,@(mapcar (lambda (method) `(call-method ,method)) before)
                          (call-method ,(first primary) ,(rest primary)))
                 ,@(mapcar (lambda (method) `(call-method ,method)) (reverse after)))))
    (if around
        `(call-method ,(first around) (,@(rest around) (make-method ,core)))
        core)))
(defclass special-construction () ((a :initform 1)))
(show (not (null (make-instance 'special-construction))))
(reinitialize-instance #'initialize-instance
                       :method-combination (clostrophilia:find-method-combination
                                            nil 'alternate-standard '()))
(show (not (clostrophilia::cached-fast-construction-p
            (find-class 'special-construction))))
