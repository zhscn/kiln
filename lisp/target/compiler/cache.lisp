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
  (loop for function in (kiln.kir::kmodule-funcs module)
        for debug = (assoc :debug-literal (cddr function))
        when debug collect (second debug)))

(defun compilation-literals-match-p (old new debug-literals)
  (and (= (length old) (length new))
       (loop for x across old for y across new for index from 0
             always (if (member index debug-literals)
                        ;; Debug records are freshly built compiler metadata.
                        (similar-literal-p x y 100)
                        (eql x y)))))

;;; Entry: package, readtable, canonical packet, literal objects, dependency versions,
;;; original module name and packet, executable init function.
(defun canonical-backend-form (form name)
  (cond ((stringp form) (replace-all (replace-all form (mangle name) "") name ""))
        ((consp form) (mapcar (lambda (x) (canonical-backend-form x name)) form))
        (t form)))

(defun cached-toplevel-init (name module literals debug-literals replayable-p)
  (when (> (length *toplevel-compilation-cache*)
           (max 0 kiln.sys:*compilation-cache-limit*))
    (setf *toplevel-compilation-cache*
          (subseq *toplevel-compilation-cache* 0 (max 0 kiln.sys:*compilation-cache-limit*))))
  (multiple-value-bind (program bindings) (kiln.kir::normalize-lir-module module literals)
    ;; Appended objects describe debug metadata; program literals retain identity checks.
    (setf debug-literals (append debug-literals
                                 (loop for index from (length literals) below (length bindings)
                                       collect index))
          literals bindings)
    (let* ((canonical (kiln.kir::encode-backend-packet (canonical-backend-form program name)
                                                    kiln.kir::+packet-lir-payload+))
           (entry (when (and replayable-p (plusp kiln.sys:*compilation-cache-limit*))
                    (find-if (lambda (entry)
                               (and (eq (svref entry 0) *package*)
                                    (eq (svref entry 1) *readtable*)
                                    (equalp (svref entry 2) canonical)
                                    (compilation-literals-match-p
                                     (svref entry 3) literals debug-literals)
                                    (compilation-versions-valid-p (svref entry 4))))
                             *toplevel-compilation-cache*))))
      (if entry
          (progn
            (incf *compilation-cache-hits*)
            (setf *toplevel-compilation-cache*
                  (cons entry (delete entry *toplevel-compilation-cache* :test #'eq)))
            (note-compiled-code (svref entry 5) (svref entry 6) (svref entry 3))
            (svref entry 7))
          (let* ((packet (kiln.kir::encode-backend-packet program kiln.kir::+packet-lir-payload+))
                 (init (kiln.sys:%primop :compile-packet packet literals)))
            (incf *compilation-cache-misses*)
            (when init
              (note-compiled-code name canonical literals)
              (when (and replayable-p (plusp kiln.sys:*compilation-cache-limit*))
                (push (vector *package* *readtable* canonical literals
                              (compilation-dependency-versions) name canonical init)
                      *toplevel-compilation-cache*)))
            (when (> (length *toplevel-compilation-cache*)
                     (max 0 kiln.sys:*compilation-cache-limit*))
              (setf *toplevel-compilation-cache*
                    (subseq *toplevel-compilation-cache* 0
                            (max 0 kiln.sys:*compilation-cache-limit*))))
            init)))))
