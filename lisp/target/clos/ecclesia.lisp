;;;; Stand-ins for the Ecclesia functions Clostrophilia calls at run time.
;;;; Ecclesia itself needs hash tables and the condition system; until they
;;;; exist (M4.5) these give the same results for valid input and do not
;;;; check lambda lists.

(in-package #:ecclesia)

(defun proper-list-p (object)
  (loop for slow = object then (cdr slow)
        for fast = object then (cddr fast)
        for first = t then nil
        do (cond ((null fast) (return t))
                 ((atom fast) (return nil))
                 ((null (cdr fast)) (return t))
                 ((atom (cdr fast)) (return nil))
                 ((and (not first) (eq slow fast)) (return nil)))))

(defun lambda-list-keyword-p (object)
  (member object '(&optional &rest &body &key &allow-other-keys &aux &whole &environment)))

(defun canonicalize-lambda-list-groups (lambda-list)
  ;; The groups of LAMBDA-LIST: the required parameters (if any), then
  ;; each lambda-list keyword with the parameters that follow it.
  (let ((groups '()) (group '()))
    (dolist (element lambda-list)
      (if (lambda-list-keyword-p element)
          (progn (when (or group groups) (push (reverse group) groups))
                 (setf group (list element)))
          (push element group)))
    (when (or group groups) (push (reverse group) groups))
    (reverse groups)))

(defun canonicalize-ordinary-lambda-list (lambda-list)
  (canonicalize-lambda-list-groups lambda-list))

(defun canonicalize-generic-function-lambda-list (lambda-list)
  (canonicalize-lambda-list-groups lambda-list))

(defun extract-required (canonicalized-lambda-list)
  (loop for group in canonicalized-lambda-list
        unless (lambda-list-keyword-p (first group))
          return group))
