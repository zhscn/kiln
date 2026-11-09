(in-package #:kiln.compiler)

;;;; Compile-time evaluation for the cross client: a form is converted to
;;;; IR (CST-TO-IR's converter and analysis), and the IR is turned into
;;;; host closures, one per node, which run it. The node kind is
;;;; dispatched on once, when the closures are built.
;;;;
;;;; Every closure of a node takes the frame of the function it runs in: a
;;;; simple-vector whose slot 0 holds the function's closure environment
;;;; and whose other slots hold the function's variables. A variable that
;;;; is captured and assigned (the analysis' cell flag) holds a cons whose
;;;; car is the value. A function object is a host closure over its
;;;; environment vector: the values (or cells) of its free variables,
;;;; in the order of IR-FUN-FREE, copied when the function object is made.
;;;; So functions made by evaluated code are ordinary host functions: macro
;;;; expanders defined at compile time are called by the converter.
;;;;
;;;; Globals are those of the compile-time environment (a Clostrum
;;;; environment): a function call reads the car of the name's operator
;;;; cell, a special variable is the car of its variable cell (the cdr is
;;;; the unbound marker), both cells looked up when the closures are
;;;; built. A dynamic binding stores the new value in the cell and restores
;;;; the old one on the way out (shallow binding), so the host functions
;;;; that the environment holds (SYMBOL-VALUE, BOUNDP) see it too.
;;;;
;;;; CATCH, THROW and UNWIND-PROTECT are the host's. A BLOCK or TAGBODY that
;;;; is left by a non-local exit (from a nested function, or from a
;;;; position that is not a tail of the BLOCK body or TAGBODY statement)
;;;; makes a fresh catch tag each time it is entered, kept in its exit
;;;; token variable. RETURN-FROM in a tail position of its BLOCK only
;;;; returns the values; GO in a tail position of a statement of its
;;;; TAGBODY returns a marker of the target (a cons private to the
;;;; TAGBODY), which the TAGBODY's statement loop recognizes.

(defvar *ir-eval-function*)              ; the IR function being built
(defvar *ir-eval-tail* '()
  "The exits (BLOCK exits and TAGBODY groups) for whose BLOCK body or
TAGBODY statement the node being built is in tail position.")
(defvar *ir-eval-client*)
(defvar *ir-eval-global*)                ; the Clostrum environment

;;; Exit information, in IR-EXIT-LOWERING while the closures are built.
;;; A BLOCK exit or a TAGBODY group: CATCH-P is set when some exit to it
;;; must throw. A TAGBODY tag: MARKER is what a GO in tail position returns.
(defstruct (ir-eval-exit (:constructor make-ir-eval-exit (&optional marker)))
  (catch-p nil) (marker nil))

;;; Variables

(defun ir-eval-assign-slots (fun)
  "Numbers the variables of FUN from 1; returns the frame size."
  (let ((index 1))
    (loop for var across (ir-buffer-data (ir-fun-vars fun))
          repeat (ir-buffer-count (ir-fun-vars fun))
          when (eq (ir-var-owner var) fun)
            do (setf (ir-var-lowering var) index)
               (incf index))
    index))

(defun ir-eval-location (var)
  "The frame index of VAR, or NIL and its index in the closure environment."
  (if (eq (ir-var-owner var) *ir-eval-function*)
      (values (ir-var-lowering var) nil)
      (values nil (or (position var (ir-fun-free *ir-eval-function*) :test #'eq)
                      (fail "IR variable ~S is missing from the closure layout"
                            (ir-var-name var))))))

(defun ir-eval-raw-reader (var)
  "A closure of a frame returning what VAR's location holds (a cell for a
cell variable)."
  (multiple-value-bind (index free) (ir-eval-location var)
    (if index
        (lambda (frame) (svref frame index))
        (lambda (frame) (svref (svref frame 0) free)))))

(defun ir-eval-reader (var)
  (multiple-value-bind (index free) (ir-eval-location var)
    (if (logtest 4 (ir-var-flags var))
        (if index
            (lambda (frame) (car (svref frame index)))
            (lambda (frame) (car (svref (svref frame 0) free))))
        (if index
            (lambda (frame) (svref frame index))
            (lambda (frame) (svref (svref frame 0) free))))))

(defun ir-eval-writer (var value)
  "A closure of a frame assigning VAR the value of the closure VALUE."
  (multiple-value-bind (index free) (ir-eval-location var)
    (cond ((and index (logtest 4 (ir-var-flags var)))
           (lambda (frame) (setf (car (svref frame index)) (funcall value frame))))
          (index (lambda (frame) (setf (svref frame index) (funcall value frame))))
          ((logtest 4 (ir-var-flags var))
           (lambda (frame) (setf (car (svref (svref frame 0) free)) (funcall value frame))))
          (t (fail "IR variable ~S is assigned but not in a cell" (ir-var-name var))))))

(defun ir-eval-binder (var)
  "A function of a frame and a value that binds VAR (a variable of the
function being built) to the value: a fresh cell for a cell variable."
  (let ((index (ir-eval-location var)))
    (unless index (fail "IR variable ~S is bound outside its function" (ir-var-name var)))
    (if (logtest 4 (ir-var-flags var))
        (lambda (frame value) (setf (svref frame index) (list value)))
        (lambda (frame value) (setf (svref frame index) value)))))

;;; Globals

(defun ir-eval-variable-cell (name)
  (clo:ensure-variable-cell *ir-eval-client* *ir-eval-global* name))

(defun ir-eval-operator-cell (name)
  (clo:ensure-operator-cell *ir-eval-client* *ir-eval-global* name))

(defmacro ir-eval-with-binding ((cell value) &body body)
  "BODY with CELL, a variable cell, holding VALUE."
  (let ((c (gensym "CELL")) (old (gensym "OLD")))
    `(let* ((,c ,cell) (,old (car ,c)))
       (setf (car ,c) ,value)
       (unwind-protect (progn ,@body)
         (setf (car ,c) ,old)))))

(defun ir-eval-designator (client global)
  "A function turning a function designator into a function, symbols
naming the compile-time environment's functions."
  (lambda (designator)
    (if (functionp designator)
        designator
        (clo:fdefinition client global designator))))

;;; Nodes

(defun ir-eval-sub (node)
  "The closure of NODE, which is not in tail position."
  (let ((*ir-eval-tail* '())) (ir-eval-node node)))

(defun ir-eval-subs (nodes)
  (map 'simple-vector #'ir-eval-sub nodes))

(defun ir-eval-constant (value)
  (lambda (frame) (declare (ignore frame)) value))

(defmacro ir-eval-call-form (function arguments frame)
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

(defun ir-eval-call (node)
  (let ((callee (ir-node-a node)) (arguments (ir-eval-subs (ir-node-b node))))
    (cond ((or (symbolp callee) (consp callee))
           (let ((cell (ir-eval-operator-cell callee)))
             (ir-eval-call-form (car cell) arguments frame)))
          ((and (ir-fun-p callee) (ir-fun-binding callee))
           (let ((function (ir-eval-reader (ir-fun-binding callee))))
             (ir-eval-call-form (funcall function frame) arguments frame)))
          ((ir-fun-p callee)
           (let ((function (ir-eval-closure callee)))
             (ir-eval-call-form (funcall function frame) arguments frame)))
          (t
           (let ((function (ir-eval-sub callee))
                 (designator (ir-eval-designator *ir-eval-client* *ir-eval-global*)))
             (ir-eval-call-form (funcall designator (funcall function frame)) arguments frame))))))

(defun ir-eval-progn (nodes)
  (let ((count (length nodes)))
    (if (zerop count)
        (ir-eval-constant nil)
        (let ((forms (map 'simple-vector #'ir-eval-sub (subseq nodes 0 (1- count))))
              (last (ir-eval-node (svref nodes (1- count)))))
          (case (length forms)
            (0 last)
            (1 (let ((a (svref forms 0)))
                 (lambda (frame) (funcall a frame) (funcall last frame))))
            (2 (let ((a (svref forms 0)) (b (svref forms 1)))
                 (lambda (frame) (funcall a frame) (funcall b frame) (funcall last frame))))
            (t (lambda (frame)
                 (loop for form across forms do (funcall form frame))
                 (funcall last frame))))))))

(defun ir-eval-let (node)
  (let ((binders (map 'simple-vector #'ir-eval-binder (ir-node-a node)))
        (inits (ir-eval-subs (ir-node-b node)))
        (body (ir-eval-node (ir-node-c node))))
    ;; The variables are new: an init form never sees an earlier one, so
    ;; each is bound as soon as its value is known.
    (cond ((ir-node-d node)
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

(defun ir-eval-if (node)
  (let ((test (ir-eval-sub (ir-node-a node)))
        (then (ir-eval-node (ir-node-b node)))
        (else (ir-eval-node (ir-node-c node))))
    (lambda (frame) (if (funcall test frame) (funcall then frame) (funcall else frame)))))

(defun ir-eval-block (node)
  (let* ((exit (ir-node-a node)) (info (make-ir-eval-exit)))
    (setf (ir-exit-lowering exit) info)
    (let ((body (let ((*ir-eval-tail* (cons exit *ir-eval-tail*))) (ir-eval-node (ir-node-b node)))))
      (if (ir-eval-exit-catch-p info)
          (let ((bind (ir-eval-binder (ir-exit-token exit))))
            (lambda (frame)
              (let ((tag (list nil)))
                (funcall bind frame tag)
                (catch tag (funcall body frame)))))
          body))))

(defun ir-eval-return (node)
  (let* ((exit (ir-node-a node)) (value (or (ir-node-b node) (ir-node 0 nil nil))))
    (if (member exit *ir-eval-tail* :test #'eq)
        (ir-eval-node value)
        (let ((token (ir-eval-reader (ir-exit-token (ir-exit-group exit))))
              (value (ir-eval-sub value)))
          (setf (ir-eval-exit-catch-p (ir-exit-lowering exit)) t)
          (lambda (frame) (throw (funcall token frame) (funcall value frame)))))))

(defun ir-eval-tagbody (node)
  (let* ((segments (ir-node-a node)) (group (ir-node-b node))
         (key (list :go)) (statements (make-ir-buffer)) (info nil))
    ;; Each segment's statements are numbered in order; a tag is the
    ;; number of its first statement. The first segment's exit is the
    ;; group, which no GO names.
    (loop for segment across segments
          do (setf (ir-exit-lowering (car segment))
                   (make-ir-eval-exit (cons key (ir-buffer-count statements))))
             (let ((form (cdr segment)))
               (cond ((= (ir-node-kind form) 10)
                      (loop for statement across (ir-node-a form) do (ir-push statement statements)))
                     ((and (= (ir-node-kind form) 0) (null (ir-node-a form))))
                     (t (ir-push form statements)))))
    (setf info (ir-exit-lowering group))
    (let* ((closures (let ((*ir-eval-tail* (list group)))
                       (map 'simple-vector #'ir-eval-node (ir-vector statements))))
           (count (length closures)))
      (flet ((run (frame pc)
               (loop while (< pc count)
                     do (let ((result (funcall (svref closures pc) frame)))
                          (if (and (consp result) (eq (car result) key))
                              (setf pc (cdr result))
                              (incf pc))))))
        (if (ir-eval-exit-catch-p info)
            (let ((bind (ir-eval-binder (ir-exit-token group))))
              (lambda (frame)
                (let ((tag (list nil)) (pc 0))
                  (funcall bind frame tag)
                  (loop (setf pc (catch tag (run frame pc) -1))
                        (when (minusp pc) (return nil))))))
            (lambda (frame) (run frame 0) nil))))))

(defun ir-eval-go (node)
  (let* ((exit (ir-node-a node)) (group (ir-exit-group exit))
         (marker (ir-eval-exit-marker (ir-exit-lowering exit))))
    (if (member group *ir-eval-tail* :test #'eq)
        (ir-eval-constant marker)
        (let ((token (ir-eval-reader (ir-exit-token group))) (pc (cdr marker)))
          (setf (ir-eval-exit-catch-p (ir-exit-lowering group)) t)
          (lambda (frame) (throw (funcall token frame) pc))))))

(defun ir-eval-progv (node)
  (let ((symbols (ir-eval-sub (ir-node-a node)))
        (values (ir-eval-sub (ir-node-b node)))
        (body (ir-eval-node (ir-node-c node)))
        (client *ir-eval-client*) (global *ir-eval-global*))
    (lambda (frame)
      (let* ((symbols (funcall symbols frame)) (values (funcall values frame))
             (cells (mapcar (lambda (symbol)
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
          (loop for cell in cells for value in old do (setf (car cell) value)))))))

(defun ir-eval-load-time-value (node)
  ;; Evaluated once, when the form that contains it is prepared.
  (ir-eval-constant (funcall (funcall (ir-eval-function (ir-node-a node)) #()))))

(defun ir-eval-node (node)
  (case (ir-node-kind node)
    (0 (ir-eval-constant (ir-node-a node)))
    (1 (ir-eval-reader (ir-node-a node)))
    (2 (ir-eval-writer (ir-node-a node) (ir-eval-sub (ir-node-b node))))
    (3 (let ((cell (ir-eval-variable-cell (ir-node-a node))) (name (ir-node-a node)))
         (lambda (frame)
           (declare (ignore frame))
           (let ((value (car cell)))
             (if (eq value (cdr cell)) (error 'unbound-variable :name name) value)))))
    (4 (let ((cell (ir-eval-variable-cell (ir-node-a node))) (value (ir-eval-sub (ir-node-b node))))
         (lambda (frame) (setf (car cell) (funcall value frame)))))
    (5 (let ((cell (ir-eval-operator-cell (ir-node-a node))))
         (lambda (frame) (declare (ignore frame)) (car cell))))
    (6 (let ((fun (ir-node-a node)))
         (if (ir-fun-binding fun)
             (ir-eval-reader (ir-fun-binding fun))
             (ir-eval-closure fun))))
    (7 (ir-eval-call node))
    (8 (let ((name (ir-node-b node)))
         (lambda (frame)
           (declare (ignore frame))
           (error "The primitive operation ~S cannot be evaluated at compile time." name))))
    (9 (ir-eval-if node))
    (10 (ir-eval-progn (ir-node-a node)))
    (11 (ir-eval-let node))
    (12 (let ((cell (ir-eval-variable-cell (ir-node-a node)))
              (value (ir-eval-sub (ir-node-b node))) (body (ir-eval-node (ir-node-c node))))
          (lambda (frame)
            (ir-eval-with-binding (cell (funcall value frame)) (funcall body frame)))))
    (13 (ir-eval-local-functions node))
    (14 (ir-eval-block node))
    (15 (ir-eval-return node))
    (16 (ir-eval-tagbody node))
    (17 (ir-eval-go node))
    (18 (let ((tag (ir-eval-sub (ir-node-a node))) (body (ir-eval-node (ir-node-b node))))
          (lambda (frame) (catch (funcall tag frame) (funcall body frame)))))
    (19 (let ((tag (ir-eval-sub (ir-node-a node))) (value (ir-eval-sub (ir-node-b node))))
          (lambda (frame) (throw (funcall tag frame) (funcall value frame)))))
    (20 (let ((form (ir-eval-node (ir-node-a node))) (cleanup (ir-eval-sub (ir-node-b node))))
          (lambda (frame) (unwind-protect (funcall form frame) (funcall cleanup frame)))))
    (21 (let ((function (ir-eval-sub (ir-node-a node))) (arguments (ir-eval-subs (ir-node-b node)))
              (designator (ir-eval-designator *ir-eval-client* *ir-eval-global*)))
          (if (= (length arguments) 1)
              (let ((argument (svref arguments 0)))
                (lambda (frame)
                  (multiple-value-call (funcall designator (funcall function frame))
                    (funcall argument frame))))
              (lambda (frame)
                (let ((function (funcall designator (funcall function frame))))
                  (apply function (loop for argument across arguments
                                        nconc (multiple-value-list (funcall argument frame)))))))))
    (22 (let ((first (ir-eval-sub (ir-node-a node))) (rest (ir-eval-sub (ir-node-b node))))
          (lambda (frame) (multiple-value-prog1 (funcall first frame) (funcall rest frame)))))
    (23 (ir-eval-node (ir-node-b node)))
    (24 (ir-eval-load-time-value node))
    (25 (ir-eval-progv node))
    (otherwise (fail "Unknown IR node kind ~S" (ir-node-kind node)))))

;;; Functions

(defun ir-eval-environment-filler (fun)
  "A function of a frame of the function being built and an environment
vector for FUN, which fills the vector with FUN's free variables."
  (let ((readers (map 'simple-vector #'ir-eval-raw-reader (ir-fun-free fun))))
    (lambda (frame environment)
      (loop for reader across readers for index from 0
            do (setf (svref environment index) (funcall reader frame)))
      environment)))

(defun ir-eval-closure (fun)
  "A closure of a frame making a function object for FUN, a lambda."
  (let ((maker (ir-eval-function fun)) (size (length (ir-fun-free fun))))
    (if (zerop size)
        (lambda (frame) (declare (ignore frame)) (funcall maker #()))
        (let ((fill (ir-eval-environment-filler fun)))
          (lambda (frame) (funcall maker (funcall fill frame (make-array size))))))))

(defun ir-eval-local-functions (node)
  (let* ((functions (ir-node-a node))
         (makers (map 'simple-vector #'ir-eval-function functions))
         (sizes (map 'simple-vector (lambda (fun) (length (ir-fun-free fun))) functions))
         (fillers (map 'simple-vector #'ir-eval-environment-filler functions))
         (binders (map 'simple-vector (lambda (fun) (ir-eval-binder (ir-fun-binding fun))) functions))
         (body (ir-eval-node (ir-node-b node))))
    (lambda (frame)
      ;; The functions can refer to one another: every function object is
      ;; bound before the environments are filled.
      (let ((environments (map 'simple-vector #'make-array sizes)))
        (loop for maker across makers for binder across binders for environment across environments
              do (funcall binder frame (funcall maker environment)))
        (loop for fill across fillers for environment across environments
              do (funcall fill frame environment)))
      (funcall body frame))))

(defun ir-eval-parameter-chain (fun body)
  "BODY preceded by the initialization of FUN's parameters that were not
supplied, in order, each special parameter bound around what follows it."
  (let ((specials (ir-fun-parameter-specials fun)) (next body))
    (dolist (parameter (reverse (ir-parameter-list fun)) next)
      (let* ((var (svref parameter 0)) (init (svref parameter 1)) (supplied (svref parameter 2))
             (special (car (rassoc var specials)))
             (rest next))
        (when special
          (let ((cell (ir-eval-variable-cell special)) (value (ir-eval-reader var)) (after rest))
            (setf rest (lambda (frame)
                         (ir-eval-with-binding (cell (funcall value frame)) (funcall after frame))))))
        (setf next
              (if supplied
                  (let ((supplied-p (ir-eval-reader supplied))
                        (initialize (ir-eval-writer var (ir-eval-sub init)))
                        (after rest))
                    (lambda (frame)
                      (unless (funcall supplied-p frame) (funcall initialize frame))
                      (funcall after frame)))
                  rest))))))

(define-condition ir-eval-argument-error (program-error simple-error) ())

(defun ir-eval-argument-error (name control &rest arguments)
  (error 'ir-eval-argument-error
         :format-control "~@[~S: ~]~?" :format-arguments (list name control arguments)))

(defun ir-eval-function (fun)
  "A function of an environment vector making a function object for FUN."
  (let* ((*ir-eval-function* fun) (*ir-eval-tail* '())
         (size (ir-eval-assign-slots fun))
         (ll (ir-fun-lambda-list fun))
         (required (map 'list #'ir-eval-binder (ir-lambda-list-required ll)))
         (name (ir-fun-name fun))
         (body (ir-eval-parameter-chain fun (ir-eval-node (ir-fun-body fun))))
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
      (if (and (zerop (length (ir-lambda-list-optional ll))) (null (ir-lambda-list-rest ll))
               (not (ir-lambda-list-key-p ll)) (<= (length required) 3))
          (ecase (length required)
            (0 (entry ()))
            (1 (entry (a)))
            (2 (entry (a b)))
            (3 (entry (a b c))))
          (ir-eval-general-entry fun size required body name)))))

(defun ir-eval-general-entry (fun size required body name)
  (let* ((ll (ir-fun-lambda-list fun))
         (optional (map 'list (lambda (parameter)
                                (cons (ir-eval-binder (svref parameter 0))
                                      (ir-eval-binder (svref parameter 2))))
                        (ir-lambda-list-optional ll)))
         (rest (and (ir-lambda-list-rest ll) (ir-eval-binder (ir-lambda-list-rest ll))))
         (key-p (ir-lambda-list-key-p ll))
         (allow-other-keys (ir-lambda-list-allow-other-keys ll))
         (keys (map 'list (lambda (parameter)
                            (list (svref parameter 3)
                                  (ir-eval-binder (svref parameter 0))
                                  (ir-eval-binder (svref parameter 2))))
                    (ir-lambda-list-keys ll))))
    (lambda (environment)
      (lambda (&rest arguments)
        (let ((frame (make-array size)) (more arguments))
          (setf (svref frame 0) environment)
          (dolist (binder required)
            (when (null more) (ir-eval-argument-error name "too few arguments: ~S" arguments))
            (funcall binder frame (pop more)))
          (loop for (binder . supplied) in optional
                do (if more
                       (progn (funcall binder frame (pop more)) (funcall supplied frame t))
                       (progn (funcall binder frame nil) (funcall supplied frame nil))))
          (when rest (funcall rest frame more))
          (cond (key-p
                 (unless (evenp (length more))
                   (ir-eval-argument-error name "odd number of keyword arguments: ~S" more))
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
                           do (ir-eval-argument-error name "unknown keyword argument ~S" (car tail)))))
                ((and more (not rest))
                 (ir-eval-argument-error name "too many arguments: ~S" arguments)))
          (funcall body frame))))))

;;; Entry points

(defun ir-eval (input environment)
  "Evaluates INPUT, a CST or a form, in the Trucler ENVIRONMENT (the
compile-time environment and the local macros visible to INPUT)."
  (let* ((*inline-enabled* nil)
         (*defined-functions* (if (boundp '*defined-functions*)
                                  *defined-functions*
                                  (make-hash-table :test 'equal)))
         (*referenced-functions* (if (boundp '*referenced-functions*)
                                     *referenced-functions*
                                     (make-hash-table :test 'equal)))
         (*ir-eval-client* *client*)
         (*ir-eval-global* (trucler:global-environment *client* environment))
         (root (make-ir-fun :name '(:top-level-form) :lambda-list (make-ir-lambda-list))))
    (let ((*ir-function* root) (*ir-source* nil) (*ir-conversion-depth* 0)
          (*ir-file-id* 0) (*ir-form-sources* nil))
      (setf (ir-fun-body root) (ir-convert input (ir-env environment)))
      (analyze-ir root))
    (funcall (funcall (ir-eval-function root) #()))))

(defun ir-macrolet-environment (environment)
  "The environment in which the expander of a local macro is evaluated:
the local macros, symbol macros and special declarations of ENVIRONMENT,
never its variables, functions, blocks or tags."
  (let ((variables '()) (functions '()) (seen-variables '()) (seen-functions '()))
    (loop for env = environment then (ir-env-parent env) while (ir-env-p env)
          do (dolist (entry (ir-env-vars env))
               (unless (member (car entry) seen-variables :test #'eq)
                 (push (car entry) seen-variables)
                 (unless (ir-var-p (cdr entry)) (push entry variables))))
             (dolist (entry (ir-env-funcs env))
               (unless (member (car entry) seen-functions :test #'equal)
                 (push (car entry) seen-functions)
                 (unless (ir-fun-p (cdr entry)) (push entry functions)))))
    (ir-env (ir-base-environment environment)
            :vars (nreverse variables) :funcs (nreverse functions))))

(defmethod evaluate-at-compile-time ((client cross-client) input environment)
  (ir-eval input environment))

(defmethod ir-local-macro-expander ((client cross-client) name lambda-list body environment)
  (ir-eval `(function ,(ecclesia:parse-macro name lambda-list body))
           (ir-macrolet-environment environment)))
