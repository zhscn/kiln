(in-package #:kiln.compiler)

;;; Frame slots, labels and exit dispatch records belong to one consumer.
;;; Sharing a semantic HIR between evaluation and native emission must not
;;; let either consumer overwrite the other's locations.
(defstruct hir-consumer-state
  (kind :native)
  (bindings (make-hash-table :test 'eq))
  (extra-bindings (make-hash-table :test 'eq))
  (functions (make-hash-table :test 'eq))
  (nodes (make-hash-table :test 'eq))
  (exits (make-hash-table :test 'eq)))
(defstruct hir-function-emission label epoch)
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

(defun hir-function-emission (function)
  (or (gethash function (hir-consumer-state-functions *hir-consumer-state*))
      (setf (gethash function (hir-consumer-state-functions *hir-consumer-state*)) (make-hir-function-emission))))
(defun hir-fun-label (function) (hir-function-emission-label (hir-function-emission function)))
(defun (setf hir-fun-label) (label function) (setf (hir-function-emission-label (hir-function-emission function)) label))
(defun hir-fun-lowering-epoch (function) (hir-function-emission-epoch (hir-function-emission function)))
(defun (setf hir-fun-lowering-epoch) (epoch function) (setf (hir-function-emission-epoch (hir-function-emission function)) epoch))
(defun hir-exit-lowering (exit) (gethash exit (hir-consumer-state-exits *hir-consumer-state*)))
(defun (setf hir-exit-lowering) (value exit) (setf (gethash exit (hir-consumer-state-exits *hir-consumer-state*)) value))

(defun hir-node-emission (node) (gethash node (hir-consumer-state-nodes *hir-consumer-state*)))
(defun (setf hir-node-emission) (value node) (setf (gethash node (hir-consumer-state-nodes *hir-consumer-state*)) value))
