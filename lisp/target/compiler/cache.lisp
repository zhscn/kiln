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

(defun compilation-hir-atom-p (object)
  (or (symbolp object) (numberp object) (characterp object)))

(defun compilation-hir-key (form)
  ;; Record syntax edges by number so lexical owners and exits can refer
  ;; back to their definitions. Global names and program literals keep
  ;; their exact identity.
  (catch 'unsupported-compilation-key
    (let ((*toplevel* form)
          (version *lowering-version*)
          (objects (make-compiler-eq-table))
          (source-objects (make-compiler-eq-table))
          (lexical-names (make-compiler-eq-table))
          (next-lexical-name 0)
          (records (make-hir-buffer))
          (literals (make-hir-buffer)))
      (labels ((literal (object)
                 (unless (compilation-hir-atom-p object)
                   (throw 'unsupported-compilation-key nil))
                 (let ((index (hir-buffer-count literals)))
                   (hir-push object literals)
                   (list :literal index)))
               (lexical-name (name)
                 (if (and name (symbolp name) (null (symbol-package name)))
                     (list :lexical (or (compiler-eq-ref lexical-names name)
                                        (setf (compiler-eq-ref lexical-names name)
                                              (prog1 next-lexical-name (incf next-lexical-name)))))
                     (visit name)))
               (fields (object source-data)
                 (typecase object
                   (hir-node
                    (let ((kind (hir-node-kind object)))
                      (vector :node kind (hir-node-source object)
                              (hir-node-policy object) (visit (hir-node-origin object) t)
                              (if (zerop kind) (literal (hir-node-a object)) (visit (hir-node-a object)))
                              (visit (hir-node-b object)) (visit (hir-node-c object)) (visit (hir-node-d object)))))
                   (hir-fun
                    (vector :function (lexical-name (hir-fun-name object)) (visit (hir-fun-parent object))
                            (visit (hir-fun-lambda-list object)) (visit (hir-fun-body object))
                            (visit (hir-fun-parameter-specials object)) (visit (hir-fun-free object))
                            (visit (hir-fun-exits object)) (visit (hir-fun-vars object)) (hir-fun-binding-count object)
                            (hir-fun-policy object) (hir-fun-source object) (visit (hir-fun-origin object) t)
                            (visit (hir-fun-binding object)) (visit (hir-fun-load-time-values object))))
                   (hir-var
                    (vector :variable (lexical-name (hir-var-name object)) (visit (hir-var-owner object))
                            (hir-var-id object) (hir-var-flags object) (hir-var-refs object)
                            (visit (hir-var-type object)) (hir-var-policy object) (source-variable-name object)))
                   (hir-exit
                    (vector :exit (lexical-name (hir-exit-name object)) (visit (hir-exit-owner object))
                            (visit (hir-exit-group object)) (visit (hir-exit-token object)) (hir-exit-flags object)
                            (hir-exit-index object)))
                   (hir-type-declaration
                    (vector :declaration (visit (hir-type-declaration-original object))
                            (visit (hir-type-declaration-expanded object))))
                   (hir-lambda-list
                    (vector :lambda-list (visit (hir-lambda-list-required object))
                            (visit (hir-lambda-list-optional object)) (visit (hir-lambda-list-rest object))
                            (visit (hir-lambda-list-keys object)) (hir-lambda-list-key-p object)
                            (hir-lambda-list-allow-other-keys object)))
                   (hir-buffer
                    (vector :buffer (map 'simple-vector #'visit (hir-vector object))))
                   (cons (vector :cons (visit (car object) source-data) (visit (cdr object) source-data)))
                   (simple-vector (vector :vector (map 'simple-vector (lambda (item) (visit item source-data)) object)))
                   (t (throw 'unsupported-compilation-key nil))))
               (visit (object &optional source-data)
                 (cond ((null object) nil)
                       ((symbolp object) (literal object))
                       ((or (numberp object) (characterp object)) object)
                       ((stringp object)
                        (unless source-data (throw 'unsupported-compilation-key nil))
                        object)
                       (t
                        (let ((table (if source-data source-objects objects)))
                          (multiple-value-bind (index present) (compiler-eq-ref table object)
                            (unless present
                              (setf index (hir-buffer-count records))
                              (when (>= index 4096) (throw 'unsupported-compilation-key nil))
                              (setf (compiler-eq-ref table object) index)
                              (hir-push nil records)
                              (setf (svref (hir-buffer-data records) index) (fields object source-data)))
                            (list :ref index)))))))
        (let ((source (vector (visit (toplevel-form-file form) t) (visit (toplevel-form-source form))
                              (visit (toplevel-form-definition form)))))
          (visit (toplevel-form-ast form))
          (vector version
                  (second (encode-source-form (vector source (hir-vector records))))
                  (hir-vector literals)))))))

(defun compilation-hir-key-match-p (a b)
  (and (eql (svref a 0) (svref b 0))
       (string= (svref a 1) (svref b 1))
       (= (length (svref a 2)) (length (svref b 2)))
       (every #'eql (svref a 2) (svref b 2))))

(defun compilation-reusable-bindings (bindings debug-indices)
  ;; Debug objects can escape through frame inspection. Keep a private
  ;; copy with the same aliases for matching or binding a new initializer.
  (catch 'unsupported-compilation-key
    (let ((copy (copy-seq bindings))
          (objects (make-compiler-eq-table)))
      (labels ((copy-debug (object)
                 (if (compilation-hir-atom-p object)
                     object
                     (or (compiler-eq-ref objects object)
                         (typecase object
                           (cons
                            (let ((cell (cons nil nil)))
                              (setf (compiler-eq-ref objects object) cell
                                    (car cell) (copy-debug (car object))
                                    (cdr cell) (copy-debug (cdr object)))
                              cell))
                           (simple-vector
                            (let ((vector (make-array (length object))))
                              (setf (compiler-eq-ref objects object) vector)
                              (dotimes (i (length object) vector)
                                (setf (svref vector i) (copy-debug (svref object i))))))
                           (string (setf (compiler-eq-ref objects object) (copy-seq object)))
                           (t (throw 'unsupported-compilation-key nil)))))))
        (dotimes (i (length copy) copy)
          (let ((object (svref copy i)))
            (if (member i debug-indices)
                (setf (svref copy i) (copy-debug object))
                (unless (compilation-hir-atom-p object)
                  (throw 'unsupported-compilation-key nil)))))))))

;;; Entry: package, readtable, packet, literals, versions, init, HIR replay.
(defun cached-toplevel-packet-init (packet literals debug-literals replayable-p replay)
  (let ((limit (max 0 kiln.sys:*compilation-cache-limit*)))
    (when (> (length *toplevel-compilation-cache*) limit)
      (setf *toplevel-compilation-cache* (subseq *toplevel-compilation-cache* 0 limit)))
    (let ((entry (when (and replayable-p (plusp limit))
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
            (when (and replay (> (length entry) 6)) (setf (svref entry 6) replay))
            (setf *toplevel-compilation-cache*
                  (cons entry (delete entry *toplevel-compilation-cache* :test #'eq)))
            (note-compiled-code packet (svref entry 3))
            (svref entry 5))
          (let ((init (with-compilation-phase (:backend)
                        (kiln.lir:require-init (kiln.sys:%primop :compile-packet packet literals) :compile-packet))))
            (incf *compilation-cache-misses*)
            (when init
              (note-compiled-code packet literals)
              (when (and replayable-p (plusp limit))
                (push (vector *package* *readtable* packet literals
                              (compilation-dependency-versions) init replay)
                      *toplevel-compilation-cache*)
                (when (> (length *toplevel-compilation-cache*) limit)
                  (setf *toplevel-compilation-cache* (subseq *toplevel-compilation-cache* 0 limit)))))
            init)))))

(defun cached-toplevel-init (module literals debug-literals replayable-p key)
  (multiple-value-bind (program bindings) (kiln.lir:module-program module literals)
    (let* ((indices (append debug-literals
                            (loop for index from (length literals) below (length bindings) collect index)))
           (template (when (and key replayable-p (eql (svref key 0) *lowering-version*))
                       (compilation-reusable-bindings bindings indices))))
      (cached-toplevel-packet-init (kiln.lir::encode-image-program program) bindings indices replayable-p
                                   (when template (list key template indices))))))

(defun find-toplevel-replay (key)
  (when (and key (eql (svref key 0) *lowering-version*))
    (loop for entry in *toplevel-compilation-cache*
          repeat kiln.sys:*compilation-cache-limit*
          for replay = (and (> (length entry) 6) (svref entry 6))
          when (and replay (eq (svref entry 0) *package*) (eq (svref entry 1) *readtable*)
                    (compilation-hir-key-match-p key (first replay)))
            return entry)))

(defun replay-toplevel-init (entry)
  (let* ((replay (svref entry 6))
         (indices (third replay))
         (bindings (compilation-reusable-bindings (second replay) indices)))
    (cached-toplevel-packet-init (svref entry 2) bindings indices t replay)))
