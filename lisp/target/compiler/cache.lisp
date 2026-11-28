;;;; Bounded native artifacts for top-level evaluation. Compilation-time effects
;;;; are replayed by the front end; only matching generated code is reused.
(in-package #:kiln.compiler)

(defvar kiln.sys:*compilation-cache-limit* 64)
(defvar *toplevel-compilation-cache* '())
(defvar *compilation-cache-hits* 0)
(defvar *compilation-cache-misses* 0)

(defun kiln.sys:clear-compilation-cache ()
  "Drops cache references to top-level artifacts and resets cache counters.
Native code already registered with the runtime follows the runtime's lifetime."
  (setf *toplevel-compilation-cache* '()
        *compilation-cache-hits* 0 *compilation-cache-misses* 0)
  nil)

(defun kiln.sys:compilation-cache-statistics ()
  "Returns cache hits, misses and retained entry count as multiple values."
  (values *compilation-cache-hits* *compilation-cache-misses*
          (length *toplevel-compilation-cache*)))

(defun compilation-dependency-versions ()
  (loop for key in (cdr *dependencies*)
        for cell = (kiln.kernel::assumption-cell (first key) (second key))
        collect (list key cell (svref cell 0))))

(defun compilation-versions-valid-p (versions)
  (every (lambda (entry)
           (let* ((key (first entry))
                  (cell (kiln.kernel::assumption-cell (first key) (second key))))
             (and (eq cell (second entry)) (eql (svref cell 0) (third entry)))))
         versions))

(defun compilation-debug-literals (module)
  (loop for function in (kiln.kir::kmodule-functions module)
        for debug = (kiln.kir::source-function-debug function)
        when (eq (first debug) :debug-literal) collect (second debug)))

(defun compilation-literals-match-p (old new debug-literals)
  (and (= (length old) (length new))
       (loop for x across old for y across new for index from 0
             always (if (member index debug-literals)
                        ;; Debug records are freshly built compiler metadata.
                        (similar-literal-p x y 100)
                        (eql x y)))))

;;; Entry: package, readtable, packet, literals, versions, and init function.
(defun cached-toplevel-init (module literals debug-literals replayable-p)
  (when (> (length *toplevel-compilation-cache*)
           (max 0 kiln.sys:*compilation-cache-limit*))
    (setf *toplevel-compilation-cache*
          (subseq *toplevel-compilation-cache* 0 (max 0 kiln.sys:*compilation-cache-limit*))))
  (multiple-value-bind (program bindings) (kiln.lir:module-program module literals)
    ;; Appended objects describe debug metadata; program literals retain identity checks.
    (setf debug-literals (append debug-literals
                                 (loop for index from (length literals) below (length bindings)
                                       collect index))
          literals bindings)
    (let* ((packet (kiln.lir:encode-program program))
           (entry (when (and replayable-p (plusp kiln.sys:*compilation-cache-limit*))
                    (find-if (lambda (entry)
                               (and (eq (svref entry 0) *package*)
                                    (eq (svref entry 1) *readtable*)
                                    (compilation-packet-equal-p (svref entry 2) packet)
                                    (compilation-literals-match-p
                                     (svref entry 3) literals debug-literals)
                                    (compilation-versions-valid-p (svref entry 4))))
                             *toplevel-compilation-cache*))))
      (if entry
          (progn
            (incf *compilation-cache-hits*)
            (setf *toplevel-compilation-cache*
                  (cons entry (delete entry *toplevel-compilation-cache* :test #'eq)))
            (note-compiled-code packet (svref entry 3))
            (svref entry 5))
          (let ((init (with-compilation-phase (:backend)
                        (kiln.lir:require-init (kiln.sys:%primop :compile-packet packet literals) :compile-packet))))
            (incf *compilation-cache-misses*)
            (when init
              (note-compiled-code packet literals)
              (when (and replayable-p (plusp kiln.sys:*compilation-cache-limit*))
                (push (vector *package* *readtable* packet literals
                              (compilation-dependency-versions) init)
                      *toplevel-compilation-cache*)))
            (when (> (length *toplevel-compilation-cache*)
                     (max 0 kiln.sys:*compilation-cache-limit*))
              (setf *toplevel-compilation-cache*
                    (subseq *toplevel-compilation-cache* 0
                            (max 0 kiln.sys:*compilation-cache-limit*))))
            init)))))
