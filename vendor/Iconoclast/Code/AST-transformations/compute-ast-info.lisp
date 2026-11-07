(cl:in-package #:iconoclast-ast-transformations)

;;; kiln: the parents, owners and function tree are found in one walk,
;;; which also lists the local functions in the order in which a walk
;;; finishes them; the escaped functions and the call graph, which need
;;; the parents and owners of all ASTs, are then computed from that list,
;;; in the order in which their own walks visited the functions. The five
;;; walks of COMPUTE-PARENT-ASTS, COMPUTE-OWNER-ASTS,
;;; COMPUTE-FUNCTION-TREE, COMPUTE-ESCAPED-FUNCTIONS and
;;; COMPUTE-CALL-GRAPH (which give the same results) took a few percent of
;;; the time of kiln compiling itself.

(defclass ast-info-client (client)
  ((%ast-info :initarg :ast-info :reader ast-info)
   (%local-function-asts :initform '() :accessor local-function-asts)))

(defmethod iaw:walk-ast-node :around ((client ast-info-client) ast)
  (let ((ast-info (ast-info client)))
    (setf (parent-ast ast ast-info) *parent-ast*)
    (setf (owner-ast ast ast-info) *owner-ast*))
  (let ((*parent-ast* ast))
    (call-next-method)))

(defmethod iaw:walk-ast-node :around
    ((client ast-info-client) (ast ico:local-function-ast))
  (let ((ast-info (ast-info client))
        (owner-ast *owner-ast*))
    (link-parent-and-child-function owner-ast ast ast-info)
    (let ((*owner-ast* ast))
      (call-next-method))
    (setf (owner-ast (ico:name-ast ast) ast-info) owner-ast)
    (setf (owner-ast ast ast-info) owner-ast)
    (push ast (local-function-asts client)))
  ast)

(defun note-escaped-function (ast ast-info)
  (let ((definition-ast (ico:name-ast ast)))
    (loop for reference-ast
            in (ico:reference-asts definition-ast)
          for parent-ast = (parent-ast reference-ast ast-info)
          unless (and (typep parent-ast 'ico:application-ast)
                      (eq reference-ast (ico:function-name-ast parent-ast)))
            do (push ast (escaped-functions ast-info))
               (loop-finish))))

(defun note-callers (ast ast-info)
  (let* ((name-ast (ico:name-ast ast))
         (reference-asts (ico:reference-asts name-ast)))
    (loop for reference-ast in reference-asts
          for parent-ast = (parent-ast reference-ast ast-info)
          when (and (typep parent-ast 'ico:application-ast)
                    (eq reference-ast (ico:function-name-ast parent-ast)))
            do (let ((caller-ast (owner-ast parent-ast ast-info)))
                 (pushnew caller-ast
                          (function-caller-asts ast ast-info)
                          :test #'eq)
                 (pushnew ast
                          (function-callee-asts caller-ast ast-info)
                          :test #'eq)))))

(defun compute-ast-info (ast)
  (let* ((ast-info (make-instance 'ast-info))
         (client (make-instance 'ast-info-client :ast-info ast-info))
         (functions
           (let ((*parent-ast* nil)
                 (*owner-ast* nil))
             (iaw:walk-ast client ast)
             (reverse (local-function-asts client)))))
    (dolist (function functions)
      (note-escaped-function function ast-info))
    (dolist (function functions)
      (note-callers function ast-info))
    ast-info))

(defclass check-ast-client (client)
  ((%ast-info :initarg :ast-info :reader ast-info)))

(defun check-definition-ast (definition-ast ast-info)
  (unless (null (owner-ast definition-ast ast-info))
    (loop for reference-ast in (ico:reference-asts definition-ast)
          for owner-ast = (owner-ast reference-ast ast-info)
          do (assert (not (null owner-ast))))))

(defmethod iaw:walk-ast-node :around
    ((client check-ast-client) (ast ico:variable-definition-ast))
  (call-next-method)
  (check-definition-ast ast (ast-info client))
  ast)

(defmethod iaw:walk-ast-node :around
    ((client check-ast-client) (ast ico:function-definition-ast))
  (call-next-method)
  (check-definition-ast ast (ast-info client))
  ast)

(defun check-ast (ast ast-info)
  (let ((client (make-instance 'check-ast-client :ast-info ast-info)))
    (iaw:walk-ast client ast)))

