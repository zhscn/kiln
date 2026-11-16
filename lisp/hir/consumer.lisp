(in-package #:kiln.compiler)

;;; HIR evaluation records frame slots and lexical exit dispatch in a
;;; separate state so compiling evaluator closures does not mutate HIR.
(defstruct hir-consumer-state
  (kind :eval)
  (bindings (make-hash-table :test 'eq))
  (extra-bindings (make-hash-table :test 'eq))
  (exits (make-hash-table :test 'eq)))
(defvar *hir-consumer-state* nil)
(defvar *hir-consumer-owner* nil)
(defvar *hir-consumer-bindings* nil)

(defun hir-consumer-slots (owner)
  (or (gethash owner (hir-consumer-state-bindings *hir-consumer-state*))
      (setf (gethash owner (hir-consumer-state-bindings *hir-consumer-state*))
            (make-array (hir-fun-binding-count owner) :initial-element nil))))

(declaim (inline hir-var-lowering))

(defun hir-var-lowering (variable)
  (let ((id (hir-var-id variable)) (owner (hir-var-owner variable)))
    (if (minusp id) (gethash variable (hir-consumer-state-extra-bindings *hir-consumer-state*))
        (let ((slots (if (eq owner *hir-consumer-owner*) *hir-consumer-bindings*
                         (gethash owner (hir-consumer-state-bindings *hir-consumer-state*)))))
          (and slots (svref slots id))))))

(defun (setf hir-var-lowering) (value variable)
  (let ((id (hir-var-id variable)) (owner (hir-var-owner variable)))
    (if (minusp id) (setf (gethash variable (hir-consumer-state-extra-bindings *hir-consumer-state*)) value)
        (setf (svref (if (eq owner *hir-consumer-owner*) *hir-consumer-bindings* (hir-consumer-slots owner)) id) value))))

(defun hir-exit-lowering (exit) (gethash exit (hir-consumer-state-exits *hir-consumer-state*)))
(defun (setf hir-exit-lowering) (value exit) (setf (gethash exit (hir-consumer-state-exits *hir-consumer-state*)) value))
