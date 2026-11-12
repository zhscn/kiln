(in-package #:kiln.compiler)

;;;; Evaluation in cross and image environments: a form is converted to
;;;; HIR (CST-TO-HIR's converter and analysis), and the HIR is turned into
;;;; host closures, one per node, which run it. The node kind is
;;;; dispatched on once, when the closures are built.
;;;;
;;;; Every closure of a node takes the frame of the function it runs in: a
;;;; simple-vector whose slot 0 holds the function's closure environment
;;;; and whose other slots hold the function's variables. A variable that
;;;; is captured and assigned (the analysis' cell flag) holds a cons whose
;;;; car is the value. A function object is a host closure over its
;;;; environment vector: the values (or cells) of its free variables,
;;;; in the order of HIR-FUN-FREE, copied when the function object is made.
;;;; So functions made by evaluated code are ordinary host functions: macro
;;;; expanders defined at compile time are called by the converter.
;;;;
;;;; Cross globals are those of the compile-time environment (a Clostrum
;;;; environment): a function call reads the car of the name's operator
;;;; cell, a special variable is the car of its variable cell (the cdr is
;;;; the unbound marker), both cells looked up when the closures are
;;;; built. A dynamic binding stores the new value in the cell and restores
;;;; the old one on the way out (shallow binding), so the host functions
;;;; that the environment holds (SYMBOL-VALUE, BOUNDP) see it too.
;;;; Image globals use FDEFINITION and SYMBOL-VALUE directly; dynamic
;;;; bindings use PROGV and therefore the runtime context.
;;;;
;;;; CATCH, THROW and UNWIND-PROTECT are the host's. A BLOCK or TAGBODY that
;;;; is left by a non-local exit (from a nested function, or from a
;;;; position that is not a tail of the BLOCK body or TAGBODY statement)
;;;; makes a fresh catch tag each time it is entered, kept in its exit
;;;; token variable. RETURN-FROM in a tail position of its BLOCK only
;;;; returns the values; GO in a tail position of a statement of its
;;;; TAGBODY returns a marker of the target (a cons private to the
;;;; TAGBODY), which the TAGBODY's statement loop recognizes.

(defvar *hir-eval-function*)              ; the HIR function being built
(defvar *hir-eval-tail* '()
  "The exits (BLOCK exits and TAGBODY groups) for whose BLOCK body or
TAGBODY statement the node being built is in tail position.")
(defvar *hir-eval-client*)
(defvar *hir-eval-global*)                ; the Clostrum environment

;;; Exit information, in HIR-EXIT-LOWERING while the closures are built.
;;; A BLOCK exit or a TAGBODY group: CATCH-P is set when some exit to it
;;; must throw. A TAGBODY tag: MARKER is what a GO in tail position returns.
(defstruct (hir-eval-exit (:constructor make-hir-eval-exit (&optional marker)))
  (catch-p nil) (marker nil))

;;; Variables

(defun hir-eval-assign-slots (fun)
  "Numbers the variables of FUN from 1; returns the frame size."
  (let ((index 1))
    (loop for var across (hir-buffer-data (hir-fun-vars fun))
          repeat (hir-buffer-count (hir-fun-vars fun))
          when (eq (hir-var-owner var) fun)
            do (setf (hir-var-lowering var) index)
               (incf index))
    index))

(defun hir-eval-location (var)
  "The frame index of VAR, or NIL and its index in the closure environment."
  (if (eq (hir-var-owner var) *hir-eval-function*)
      (values (hir-var-lowering var) nil)
      (values nil (or (position var (hir-fun-free *hir-eval-function*) :test #'eq)
                      (fail "HIR variable ~S is missing from the closure layout"
                            (hir-var-name var))))))

(defun hir-eval-raw-reader (var)
  "A closure of a frame returning what VAR's location holds (a cell for a
cell variable)."
  (multiple-value-bind (index free) (hir-eval-location var)
    (if index
        (lambda (frame) (svref frame index))
        (lambda (frame) (svref (svref frame 0) free)))))

(defun hir-eval-reader (var)
  (multiple-value-bind (index free) (hir-eval-location var)
    (if (logtest 4 (hir-var-flags var))
        (if index
            (lambda (frame) (car (svref frame index)))
            (lambda (frame) (car (svref (svref frame 0) free))))
        (if index
            (lambda (frame) (svref frame index))
            (lambda (frame) (svref (svref frame 0) free))))))

(defun hir-eval-writer (var value)
  "A closure of a frame assigning VAR the value of the closure VALUE."
  (multiple-value-bind (index free) (hir-eval-location var)
    (cond ((and index (logtest 4 (hir-var-flags var)))
           (lambda (frame) (setf (car (svref frame index)) (funcall value frame))))
          (index (lambda (frame) (setf (svref frame index) (funcall value frame))))
          ((logtest 4 (hir-var-flags var))
           (lambda (frame) (setf (car (svref (svref frame 0) free)) (funcall value frame))))
          (t (fail "HIR variable ~S is assigned but not in a cell" (hir-var-name var))))))

(defun hir-eval-binder (var)
  "A function of a frame and a value that binds VAR (a variable of the
function being built) to the value: a fresh cell for a cell variable."
  (let ((index (hir-eval-location var)))
    (unless index (fail "HIR variable ~S is bound outside its function" (hir-var-name var)))
    (if (logtest 4 (hir-var-flags var))
        (lambda (frame value) (setf (svref frame index) (list value)))
        (lambda (frame value) (setf (svref frame index) value)))))

;;; Globals

(defun hir-eval-variable-cell (name)
  (if (compiles-into-image-p *hir-eval-client*)
      name
      (clo:ensure-variable-cell *hir-eval-client* *hir-eval-global* name)))

(defun hir-eval-global-function (name)
  (if (compiles-into-image-p *hir-eval-client*)
      (lambda () (fdefinition name))
      (let ((cell (clo:ensure-operator-cell *hir-eval-client* *hir-eval-global* name)))
        (lambda () (car cell)))))

(defun hir-eval-set-global-value (cell value)
  (if (symbolp cell) (setf (symbol-value cell) value) (setf (car cell) value)))

(defmacro hir-eval-with-binding ((cell value) &body body)
  "Bind an image special through the runtime, or a cross-environment cell."
  (let ((c (gensym "CELL")) (v (gensym "VALUE")) (old (gensym "OLD")))
    `(let* ((,c ,cell) (,v ,value))
       (if (symbolp ,c)
           (progv (list ,c) (list ,v) ,@body)
           (let ((,old (car ,c)))
             (setf (car ,c) ,v)
             (unwind-protect (progn ,@body)
               (setf (car ,c) ,old)))))))

(defun hir-eval-designator (client global)
  "Resolve function designators in the environment owning the evaluated code."
  (if (compiles-into-image-p client)
      (lambda (designator)
        (if (functionp designator) designator (fdefinition designator)))
      (lambda (designator)
        (if (functionp designator) designator (clo:fdefinition client global designator)))))

;;; Nodes

(defun hir-eval-sub (node)
  "The closure of NODE, which is not in tail position."
  (let ((*hir-eval-tail* '())) (hir-eval-node node)))

(defun hir-eval-subs (nodes)
  (map 'simple-vector #'hir-eval-sub nodes))

(defun hir-eval-constant (value)
  (lambda (frame) (declare (ignore frame)) value))

(defmacro hir-eval-call-form (function arguments frame)
  "A closure calling the value of the form FUNCTION (evaluated in the
closure, before the arguments) with the values of the closures in the
simple-vector ARGUMENTS, the arity dispatched on when the closure is made."
  (let ((a (gensym "A")) (b (gensym "B")) (c (gensym "C")) (d (gensym "D")))
    `(case (length ,arguments)
       (0 (lambda (,frame) (declare (ignorable ,frame)) (funcall ,function)))
       (1 (let ((,a (svref ,arguments 0)))
            (lambda (,frame) (funcall ,function (funcall ,a ,frame)))))
       (2 (let ((,a (svref ,arguments 0)) (,b (svref ,arguments 1)))
            (lambda (,frame) (funcall ,function (funcall ,a ,frame) (funcall ,b ,frame)))))
       (3 (let ((,a (svref ,arguments 0)) (,b (svref ,arguments 1)) (,c (svref ,arguments 2)))
            (lambda (,frame)
              (funcall ,function (funcall ,a ,frame) (funcall ,b ,frame) (funcall ,c ,frame)))))
       (4 (let ((,a (svref ,arguments 0)) (,b (svref ,arguments 1))
                (,c (svref ,arguments 2)) (,d (svref ,arguments 3)))
            (lambda (,frame)
              (funcall ,function (funcall ,a ,frame) (funcall ,b ,frame)
                       (funcall ,c ,frame) (funcall ,d ,frame)))))
       (t (lambda (,frame)
            (apply ,function (loop for ,a across ,arguments collect (funcall ,a ,frame))))))))

(defun hir-eval-call (node)
  (let ((callee (hir-node-a node)) (arguments (hir-eval-subs (hir-node-b node))))
    (cond ((or (symbolp callee) (consp callee))
           (let ((reader (hir-eval-global-function callee)))
             (hir-eval-call-form (funcall reader) arguments frame)))
          ((and (hir-fun-p callee) (hir-fun-binding callee))
           (let ((function (hir-eval-reader (hir-fun-binding callee))))
             (hir-eval-call-form (funcall function frame) arguments frame)))
          ((hir-fun-p callee)
           (let ((function (hir-eval-closure callee)))
             (hir-eval-call-form (funcall function frame) arguments frame)))
          (t
           (let ((function (hir-eval-sub callee))
                 (designator (hir-eval-designator *hir-eval-client* *hir-eval-global*)))
             (hir-eval-call-form (funcall designator (funcall function frame)) arguments frame))))))

(defun hir-eval-progn (nodes)
  (let ((count (length nodes)))
    (if (zerop count)
        (hir-eval-constant nil)
        (let ((forms (map 'simple-vector #'hir-eval-sub (subseq nodes 0 (1- count))))
              (last (hir-eval-node (svref nodes (1- count)))))
          (case (length forms)
            (0 last)
            (1 (let ((a (svref forms 0)))
                 (lambda (frame) (funcall a frame) (funcall last frame))))
            (2 (let ((a (svref forms 0)) (b (svref forms 1)))
                 (lambda (frame) (funcall a frame) (funcall b frame) (funcall last frame))))
            (t (lambda (frame)
                 (loop for form across forms do (funcall form frame))
                 (funcall last frame))))))))

(defun hir-eval-let (node)
  (let ((binders (map 'simple-vector #'hir-eval-binder (hir-node-a node)))
        (inits (hir-eval-subs (hir-node-b node)))
        (body (hir-eval-node (hir-node-c node))))
    ;; The variables are new: an init form never sees an earlier one, so
    ;; each is bound as soon as its value is known.
    (cond ((hir-node-d node)
           (let ((init (svref inits 0)))
             (lambda (frame)
               (let ((values (multiple-value-list (funcall init frame))))
                 (loop for binder across binders
                       do (funcall binder frame (pop values))))
               (funcall body frame))))
          ((= (length binders) 1)
           (let ((binder (svref binders 0)) (init (svref inits 0)))
             (lambda (frame) (funcall binder frame (funcall init frame)) (funcall body frame))))
          (t
           (lambda (frame)
             (loop for binder across binders for init across inits
                   do (funcall binder frame (funcall init frame)))
             (funcall body frame))))))

(defun hir-eval-if (node)
  (let ((test (hir-eval-sub (hir-node-a node)))
        (then (hir-eval-node (hir-node-b node)))
        (else (hir-eval-node (hir-node-c node))))
    (lambda (frame) (if (funcall test frame) (funcall then frame) (funcall else frame)))))

(defun hir-eval-block (node)
  (let* ((exit (hir-node-a node)) (info (make-hir-eval-exit)))
    (setf (hir-exit-lowering exit) info)
    (let ((body (let ((*hir-eval-tail* (cons exit *hir-eval-tail*))) (hir-eval-node (hir-node-b node)))))
      (if (hir-eval-exit-catch-p info)
          (let ((bind (hir-eval-binder (hir-exit-token exit))))
            (lambda (frame)
              (let ((tag (list nil)))
                (funcall bind frame tag)
                (catch tag (funcall body frame)))))
          body))))

(defun hir-eval-return (node)
  (let* ((exit (hir-node-a node)) (value (or (hir-node-b node) (hir-node 0 nil nil))))
    (if (member exit *hir-eval-tail* :test #'eq)
        (hir-eval-node value)
        (let ((token (hir-eval-reader (hir-exit-token (hir-exit-group exit))))
              (value (hir-eval-sub value)))
          (setf (hir-eval-exit-catch-p (hir-exit-lowering exit)) t)
          (lambda (frame) (throw (funcall token frame) (funcall value frame)))))))

(defun hir-eval-tagbody (node)
  (let* ((segments (hir-node-a node)) (group (hir-node-b node))
         (key (list :go)) (statements (make-hir-buffer)) (info nil))
    ;; Each segment's statements are numbered in order; a tag is the
    ;; number of its first statement. The first segment's exit is the
    ;; group, which no GO names.
    (loop for segment across segments
          do (setf (hir-exit-lowering (car segment))
                   (make-hir-eval-exit (cons key (hir-buffer-count statements))))
             (let ((form (cdr segment)))
               (cond ((= (hir-node-kind form) 10)
                      (loop for statement across (hir-node-a form) do (hir-push statement statements)))
                     ((and (= (hir-node-kind form) 0) (null (hir-node-a form))))
                     (t (hir-push form statements)))))
    (setf info (hir-exit-lowering group))
    (let* ((closures (let ((*hir-eval-tail* (list group)))
                       (map 'simple-vector #'hir-eval-node (hir-vector statements))))
           (count (length closures)))
      (flet ((run (frame pc)
               (loop while (< pc count)
                     do (let ((result (funcall (svref closures pc) frame)))
                          (if (and (consp result) (eq (car result) key))
                              (setf pc (cdr result))
                              (incf pc))))))
        (if (hir-eval-exit-catch-p info)
            (let ((bind (hir-eval-binder (hir-exit-token group))))
              (lambda (frame)
                (let ((tag (list nil)) (pc 0))
                  (funcall bind frame tag)
                  (loop (setf pc (catch tag (run frame pc) -1))
                        (when (minusp pc) (return nil))))))
            (lambda (frame) (run frame 0) nil))))))

(defun hir-eval-go (node)
  (let* ((exit (hir-node-a node)) (group (hir-exit-group exit))
         (marker (hir-eval-exit-marker (hir-exit-lowering exit))))
    (if (member group *hir-eval-tail* :test #'eq)
        (hir-eval-constant marker)
        (let ((token (hir-eval-reader (hir-exit-token group))) (pc (cdr marker)))
          (setf (hir-eval-exit-catch-p (hir-exit-lowering group)) t)
          (lambda (frame) (throw (funcall token frame) pc))))))

(defun hir-eval-progv (node)
  (let ((symbols (hir-eval-sub (hir-node-a node)))
        (values (hir-eval-sub (hir-node-b node)))
        (body (hir-eval-node (hir-node-c node)))
        (client *hir-eval-client*) (global *hir-eval-global*)
        (imagep (compiles-into-image-p *hir-eval-client*)))
    (lambda (frame)
      (let* ((symbols (funcall symbols frame)) (values (funcall values frame)))
        (if imagep
            (progv symbols values (funcall body frame))
            (let* ((cells (mapcar (lambda (symbol)
                              (check-type symbol symbol)
                              (clo:ensure-variable-cell client global symbol))
                            symbols))
             (old (mapcar #'car cells)))
        (unwind-protect
             (progn
               ;; Symbols without a value become unbound.
               (loop for cell in cells
                     do (setf (car cell) (if values (pop values) (cdr cell))))
               (funcall body frame))
          (loop for cell in cells for value in old do (setf (car cell) value)))))))))

(defun hir-eval-load-time-value (node)
  ;; Evaluated once, when the form that contains it is prepared.
  (hir-eval-constant (funcall (funcall (hir-eval-function (hir-node-a node)) #()))))

(defun hir-eval-node (node)
  (case (hir-node-kind node)
    (0 (hir-eval-constant (hir-node-a node)))
    (1 (hir-eval-reader (hir-node-a node)))
    (2 (hir-eval-writer (hir-node-a node) (hir-eval-sub (hir-node-b node))))
    (3 (let ((cell (hir-eval-variable-cell (hir-node-a node))) (name (hir-node-a node)))
         (lambda (frame)
           (declare (ignore frame))
           (if (symbolp cell)
               (symbol-value cell)
               (let ((value (car cell)))
                 (if (eq value (cdr cell)) (error 'unbound-variable :name name) value))))))
    (4 (let ((cell (hir-eval-variable-cell (hir-node-a node))) (value (hir-eval-sub (hir-node-b node))))
         (lambda (frame) (hir-eval-set-global-value cell (funcall value frame)))))
    (5 (let ((reader (hir-eval-global-function (hir-node-a node))))
         (lambda (frame) (declare (ignore frame)) (funcall reader))))
    (6 (let ((fun (hir-node-a node)))
         (if (hir-fun-binding fun)
             (hir-eval-reader (hir-fun-binding fun))
             (hir-eval-closure fun))))
    (7 (hir-eval-call node))
    (8 (let ((name (hir-node-b node))
              (arguments (hir-eval-subs (hir-node-a node)))
              (imagep (compiles-into-image-p *hir-eval-client*)))
         (lambda (frame)
           (if imagep
               (apply #'kiln.sys:%primop name
                      (loop for argument across arguments collect (funcall argument frame)))
               (error "The primitive operation ~S cannot be evaluated in a cross environment." name)))))
    (9 (hir-eval-if node))
    (10 (hir-eval-progn (hir-node-a node)))
    (11 (hir-eval-let node))
    (12 (let ((cell (hir-eval-variable-cell (hir-node-a node)))
              (value (hir-eval-sub (hir-node-b node))) (body (hir-eval-node (hir-node-c node))))
          (lambda (frame)
            (hir-eval-with-binding (cell (funcall value frame)) (funcall body frame)))))
    (13 (hir-eval-local-functions node))
    (14 (hir-eval-block node))
    (15 (hir-eval-return node))
    (16 (hir-eval-tagbody node))
    (17 (hir-eval-go node))
    (18 (let ((tag (hir-eval-sub (hir-node-a node))) (body (hir-eval-node (hir-node-b node))))
          (lambda (frame) (catch (funcall tag frame) (funcall body frame)))))
    (19 (let ((tag (hir-eval-sub (hir-node-a node))) (value (hir-eval-sub (hir-node-b node))))
          (lambda (frame) (throw (funcall tag frame) (funcall value frame)))))
    (20 (let ((form (hir-eval-node (hir-node-a node))) (cleanup (hir-eval-sub (hir-node-b node))))
          (lambda (frame) (unwind-protect (funcall form frame) (funcall cleanup frame)))))
    (21 (let ((function (hir-eval-sub (hir-node-a node))) (arguments (hir-eval-subs (hir-node-b node)))
              (designator (hir-eval-designator *hir-eval-client* *hir-eval-global*)))
          (if (= (length arguments) 1)
              (let ((argument (svref arguments 0)))
                (lambda (frame)
                  (multiple-value-call (funcall designator (funcall function frame))
                    (funcall argument frame))))
              (lambda (frame)
                (let ((function (funcall designator (funcall function frame))))
                  (apply function (loop for argument across arguments
                                        nconc (multiple-value-list (funcall argument frame)))))))))
    (22 (let ((first (hir-eval-sub (hir-node-a node))) (rest (hir-eval-sub (hir-node-b node))))
          (lambda (frame) (multiple-value-prog1 (funcall first frame) (funcall rest frame)))))
    (23 (hir-eval-node (hir-node-b node)))
    (24 (hir-eval-load-time-value node))
    (25 (hir-eval-progv node))
    (otherwise (fail "Unknown HIR node kind ~S" (hir-node-kind node)))))

;;; Functions

(defun hir-eval-environment-filler (fun)
  "A function of a frame of the function being built and an environment
vector for FUN, which fills the vector with FUN's free variables."
  (let ((readers (map 'simple-vector #'hir-eval-raw-reader (hir-fun-free fun))))
    (lambda (frame environment)
      (loop for reader across readers for index from 0
            do (setf (svref environment index) (funcall reader frame)))
      environment)))

(defun hir-eval-closure (fun)
  "A closure of a frame making a function object for FUN, a lambda."
  (let ((maker (hir-eval-function fun)) (size (length (hir-fun-free fun))))
    (if (zerop size)
        (lambda (frame) (declare (ignore frame)) (funcall maker #()))
        (let ((fill (hir-eval-environment-filler fun)))
          (lambda (frame) (funcall maker (funcall fill frame (make-array size))))))))

(defun hir-eval-local-functions (node)
  (let* ((functions (hir-node-a node))
         (makers (map 'simple-vector #'hir-eval-function functions))
         (sizes (map 'simple-vector (lambda (fun) (length (hir-fun-free fun))) functions))
         (fillers (map 'simple-vector #'hir-eval-environment-filler functions))
         (binders (map 'simple-vector (lambda (fun) (hir-eval-binder (hir-fun-binding fun))) functions))
         (body (hir-eval-node (hir-node-b node))))
    (lambda (frame)
      ;; The functions can refer to one another: every function object is
      ;; bound before the environments are filled.
      (let ((environments (map 'simple-vector #'make-array sizes)))
        (loop for maker across makers for binder across binders for environment across environments
              do (funcall binder frame (funcall maker environment)))
        (loop for fill across fillers for environment across environments
              do (funcall fill frame environment)))
      (funcall body frame))))

(defun hir-eval-parameter-chain (fun body)
  "BODY preceded by the initialization of FUN's parameters that were not
supplied, in order, each special parameter bound around what follows it."
  (let ((specials (hir-fun-parameter-specials fun)) (next body))
    (dolist (parameter (reverse (hir-parameter-list fun)) next)
      (let* ((var (svref parameter 0)) (init (svref parameter 1)) (supplied (svref parameter 2))
             (special (car (rassoc var specials)))
             (rest next))
        (when special
          (let ((cell (hir-eval-variable-cell special)) (value (hir-eval-reader var)) (after rest))
            (setf rest (lambda (frame)
                         (hir-eval-with-binding (cell (funcall value frame)) (funcall after frame))))))
        (setf next
              (if supplied
                  (let ((supplied-p (hir-eval-reader supplied))
                        (initialize (hir-eval-writer var (hir-eval-sub init)))
                        (after rest))
                    (lambda (frame)
                      (unless (funcall supplied-p frame) (funcall initialize frame))
                      (funcall after frame)))
                  rest))))))

(define-condition hir-eval-argument-error (program-error simple-error) ())

(defun hir-eval-argument-error (name control &rest arguments)
  (error 'hir-eval-argument-error
         :format-control "~@[~S: ~]~?" :format-arguments (list name control arguments)))

(defun hir-eval-function (fun)
  "A function of an environment vector making a function object for FUN."
  (let* ((*hir-eval-function* fun) (*hir-eval-tail* '())
         (size (hir-eval-assign-slots fun))
         (ll (hir-fun-lambda-list fun))
         (required (map 'list #'hir-eval-binder (hir-lambda-list-required ll)))
         (name (hir-fun-name fun))
         (body (hir-eval-parameter-chain fun (hir-eval-node (hir-fun-body fun))))
         (r0 (first required)) (r1 (second required)) (r2 (third required)))
    (declare (ignorable r0 r1 r2))
    (macrolet ((entry (parameters)
                 `(lambda (environment)
                    (lambda ,parameters
                      (let ((frame (make-array size)))
                        (setf (svref frame 0) environment)
                        ,@(loop for parameter in parameters for binder in '(r0 r1 r2)
                                collect `(funcall ,binder frame ,parameter))
                        (funcall body frame))))))
      (if (and (zerop (length (hir-lambda-list-optional ll))) (null (hir-lambda-list-rest ll))
               (not (hir-lambda-list-key-p ll)) (<= (length required) 3))
          (ecase (length required)
            (0 (entry ()))
            (1 (entry (a)))
            (2 (entry (a b)))
            (3 (entry (a b c))))
          (hir-eval-general-entry fun size required body name)))))

(defun hir-eval-general-entry (fun size required body name)
  (let* ((ll (hir-fun-lambda-list fun))
         (optional (map 'list (lambda (parameter)
                                (cons (hir-eval-binder (svref parameter 0))
                                      (hir-eval-binder (svref parameter 2))))
                        (hir-lambda-list-optional ll)))
         (rest (and (hir-lambda-list-rest ll) (hir-eval-binder (hir-lambda-list-rest ll))))
         (key-p (hir-lambda-list-key-p ll))
         (allow-other-keys (hir-lambda-list-allow-other-keys ll))
         (keys (map 'list (lambda (parameter)
                            (list (svref parameter 3)
                                  (hir-eval-binder (svref parameter 0))
                                  (hir-eval-binder (svref parameter 2))))
                    (hir-lambda-list-keys ll))))
    (lambda (environment)
      (lambda (&rest arguments)
        (let ((frame (make-array size)) (more arguments))
          (setf (svref frame 0) environment)
          (dolist (binder required)
            (when (null more) (hir-eval-argument-error name "too few arguments: ~S" arguments))
            (funcall binder frame (pop more)))
          (loop for (binder . supplied) in optional
                do (if more
                       (progn (funcall binder frame (pop more)) (funcall supplied frame t))
                       (progn (funcall binder frame nil) (funcall supplied frame nil))))
          (when rest (funcall rest frame more))
          (cond (key-p
                 (unless (evenp (length more))
                   (hir-eval-argument-error name "odd number of keyword arguments: ~S" more))
                 (loop for (keyword binder supplied) in keys
                       do (loop for tail on more by #'cddr
                                when (eq (car tail) keyword)
                                  do (funcall binder frame (cadr tail))
                                     (funcall supplied frame t)
                                     (return)
                                finally (funcall binder frame nil)
                                        (funcall supplied frame nil)))
                 (unless (or allow-other-keys (getf more :allow-other-keys))
                   (loop for tail on more by #'cddr
                         unless (or (eq (car tail) :allow-other-keys)
                                    (find (car tail) keys :key #'first))
                           do (hir-eval-argument-error name "unknown keyword argument ~S" (car tail)))))
                ((and more (not rest))
                 (hir-eval-argument-error name "too many arguments: ~S" arguments)))
          (funcall body frame))))))

;;; Entry points

(defun hir-eval (input environment)
  "Evaluates INPUT, a CST or a form, in the Trucler ENVIRONMENT (the
compile-time environment and the local macros visible to INPUT)."
  (let* ((*inline-enabled* nil)
         (*defined-functions* (if (boundp '*defined-functions*)
                                  *defined-functions*
                                  (make-hash-table :test 'equal)))
         (*referenced-functions* (if (boundp '*referenced-functions*)
                                     *referenced-functions*
                                     (make-hash-table :test 'equal)))
         (*hir-eval-client* *client*)
         (*hir-eval-global* (trucler:global-environment *client* environment))
         (root (make-hir-fun :name '(:top-level-form) :lambda-list (make-hir-lambda-list))))
    (let ((*hir-function* root) (*hir-source* nil) (*hir-conversion-depth* 0)
          (*hir-file-id* 0) (*hir-top-cst* nil) (*hir-form-sources* nil))
      (setf (hir-fun-body root) (hir-convert input (hir-env environment)))
      (analyze-hir root))
    (funcall (funcall (hir-eval-function root) #()))))

(defun hir-macrolet-environment (environment)
  "The environment in which the expander of a local macro is evaluated:
the local macros, symbol macros and special declarations of ENVIRONMENT,
never its variables, functions, blocks or tags."
  (let ((variables '()) (functions '()) (seen-variables '()) (seen-functions '()))
    (loop for env = environment then (hir-env-parent env) while (hir-env-p env)
          do (dolist (entry (hir-env-vars env))
               (unless (member (car entry) seen-variables :test #'eq)
                 (push (car entry) seen-variables)
                 (unless (hir-var-p (cdr entry)) (push entry variables))))
             (dolist (entry (hir-env-funcs env))
               (unless (member (car entry) seen-functions :test #'equal)
                 (push (car entry) seen-functions)
                 (unless (hir-fun-p (cdr entry)) (push entry functions)))))
    (hir-env (hir-base-environment environment)
            :vars (nreverse variables) :funcs (nreverse functions))))

(defmethod evaluate-at-compile-time ((client cross-client) input environment)
  (hir-eval input environment))

(defmethod hir-local-macro-expander ((client cross-client) name lambda-list body environment)
  (hir-eval `(function ,(ecclesia:parse-macro name lambda-list body))
           (hir-macrolet-environment environment)))
