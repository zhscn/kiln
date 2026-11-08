(cl:in-package #:iconoclast-ast-walker)

;;;; This function implements a general AST walker.  All it does it
;;;; traverse the AST tree without invoking any action.  To implement
;;;; some action, client code can define an :AROUND method on
;;;; WALK-AST-NODE that specializes to a particular CLIENT class.
;;;; That :AROUND method can then implement actions before or after
;;;; recursive processing takes place, or call WALK-AST-NODE
;;;; recursively with some new AST node.  If the client-provided
;;;; :AROUND method does not end up calling CALL-NEXT-METHOD it must
;;;; return an AST which the walker will substitute into the AST tree
;;;; in place of the original AST.

;;;; As it turns out, the AST tree is not quite a tree in that ASTs
;;;; defining variables, functions, block names, and tagbody tags are
;;;; linked to their referencing ASTS, and vice versa.  We want to
;;;; avoid such traversal, not only becase it would give us an
;;;; infinite computation, but we want to traverse such pairs of ASTS
;;;; as if those links do not exist.  We handle this situation by
;;;; defining an intermediate generic function MAYBE-WALK that takes
;;;; two ASTs and calls WALK-AST-NODE only when appropriate.

(defgeneric walk-ast-node (client node))

(defgeneric maybe-walk (client parent-node child-node))

;;; By default, we call WALK-AST-NODE.
(defmethod maybe-walk (client parent-node child-node)
  (walk-ast-node client child-node))

(defmethod maybe-walk (client (parent-node ico:function-name-ast) child-node)
  child-node)

(defmethod maybe-walk (client (parent-node ico:variable-name-ast) child-node)
  child-node)

(defmethod maybe-walk (client (parent-node ico:block-name-ast) child-node)
  child-node)

;;; A TAG-AST is considered a leaf, be it a definition or a reference.
(defmethod maybe-walk (client (parent-node ico:tag-ast) child-node)
  child-node)

(defmethod walk-ast-node (client node)
  node)

;;; kiln: the walk of a node follows a plan made once for its class: for
;;; each slot designator, its cardinality, reader and slot name (the slot
;;; whose initarg is the keyword of the reader's name, which is what
;;; REINITIALIZE-INSTANCE would set: no AST class has methods on
;;; REINITIALIZE-INSTANCE or SHARED-INITIALIZE; NIL if there is none).
;;; SLOT-DESIGNATORS has the APPEND method combination, so each call made
;;; a new list; interning the keyword and calling REINITIALIZE-INSTANCE,
;;; two generic functions with &REST parameters, for every slot of every
;;; node in each pass of the AST transformations took a third of the time
;;; of kiln compiling itself. A slot is written only when its child
;;; changed.
(defvar *walk-plans* (make-hash-table :test #'eq)) ; class -> ((cardinality reader slot) ...)

(defun slot-name-for-reader (class reader-name)
  (let* ((initarg (intern (symbol-name reader-name) (find-package "KEYWORD")))
         (slot (find-if (lambda (slot)
                          (member initarg (closer-mop:slot-definition-initargs slot)))
                        (closer-mop:class-slots class))))
    (if slot (closer-mop:slot-definition-name slot) nil)))

(defun walk-plan (ast)
  (let ((class (class-of ast)))
    (or (gethash class *walk-plans*)
        (let ((plan (loop for (cardinality reader) in (iconoclast:slot-designators ast)
                          collect (list cardinality reader
                                        (slot-name-for-reader class reader)))))
          (setf (gethash class *walk-plans*) plan)
          ;; kiln: the plan rests on the AST classes not being redefined; a
          ;; redefinition of one drops its plan.
          #+kiln (kiln.kernel::register-assumption-dependent
                  :class class
                  (lambda () (remhash class *walk-plans*)))
          plan))))

(defun set-slot (ast reader-name slot-name value)
  (if slot-name
      (setf (slot-value ast slot-name) value)
      (reinitialize-instance ast (intern (symbol-name reader-name) (find-package "KEYWORD"))
                             value))
  ast)

(defmethod walk-ast-node (client (ast iconoclast:ast))
  (loop for (cardinality slot-reader slot-name) in (walk-plan ast)
        do (ecase cardinality
             (*
              (let* ((children (funcall slot-reader ast))
                     (results (loop for child in children
                                    collect (maybe-walk client ast child))))
                (unless (loop for child in children
                              for result in results
                              always (eq child result))
                  (set-slot ast slot-reader slot-name results))))
             (iconoclast:?
              (let ((possible-child (funcall slot-reader ast)))
                (unless (null possible-child)
                  (let ((result (maybe-walk client ast possible-child)))
                    (unless (or (null result) (eq result possible-child))
                      (set-slot ast slot-reader slot-name result))))))
             (1
              (let* ((child (funcall slot-reader ast))
                     (result (maybe-walk client ast child)))
                (unless (or (null result) (eq result child))
                  (set-slot ast slot-reader slot-name result))))))
  ast)

(defvar *visited*)

(defmethod walk-ast-node :around (client node)
  (if (gethash node *visited*)
      node
      (progn 
        (setf (gethash node *visited*) t)
        (call-next-method))))

(defgeneric walk-ast (client ast))

(defmethod walk-ast (client ast)
  (let ((*visited* (make-hash-table :test #'eq)))
    (walk-ast-node client ast)))
