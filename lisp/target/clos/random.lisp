;;;; Random numbers (CLHS 12.1.7): RANDOM, *RANDOM-STATE*,
;;;; MAKE-RANDOM-STATE. A random state is a structure holding Marsaglia's
;;;; xorshift128 generator: four 32-bit words, so all its arithmetic is on
;;;; fixnums. Not cryptographic; the same seed gives the same sequence.

(in-package #:kiln.kernel)

(defstruct (random-state (:constructor %make-random-state (a b c d))
                         (:constructor %read-random-state)
                         (:copier nil))
  (a 0 :type fixnum) (b 0 :type fixnum) (c 0 :type fixnum) (d 0 :type fixnum))

(defun seeded-random-state (seed)
  ;; Spreads SEED over the four words (splitmix-like), none all zero.
  (flet ((word (k)
           (let ((x (logand (+ seed (* k #x9E3779B9)) #xFFFFFFFF)))
             (setq x (logand (* (logxor x (ash x -16)) #x45D9F3B) #xFFFFFFFF))
             (setq x (logand (* (logxor x (ash x -16)) #x45D9F3B) #xFFFFFFFF))
             (logior 1 (logxor x (ash x -16))))))
    (%make-random-state (word 1) (word 2) (word 3) (word 4))))

(declaim (inline random-step))
(defun random-step (x w)
  (let ((tt (%primop :fixnum-logxor x
             (%primop :fixnum-logand (%primop :fixnum-shift-left x 11) #xffffffff))))
    (%primop :fixnum-logxor
             (%primop :fixnum-logxor w (%primop :fixnum-shift-right w 19))
             (%primop :fixnum-logxor tt (%primop :fixnum-shift-right tt 8)))))

(defun random-word (state)
  "The next 32 random bits of STATE."
  (let ((x (random-state-a state))
        (w (random-state-d state)))
    (setf (random-state-a state) (random-state-b state)
          (random-state-b state) (random-state-c state)
          (random-state-c state) w
          (random-state-d state) (random-step x w))))

(declaim (inline random-word-pair))
(defun random-word-pair (state high-mask)
  ;; Advance twice using the original slots. The first step's output
  ;; feeds the second step and becomes the new third word.
  (unless (random-state-p state)
    (error 'type-error :datum state :expected-type 'random-state))
  ;; The structure predicate checks the layout shared by A, B, C and D.
  (let* ((a (the fixnum (%primop :structure-slot state 0)))
         (b (the fixnum (%primop :structure-slot state 1)))
         (c (the fixnum (%primop :structure-slot state 2)))
         (d (the fixnum (%primop :structure-slot state 3)))
         (high (random-step a d))
         (low (random-step b high)))
    (%primop :set-structure-slot state 0 c)
    (%primop :set-structure-slot state 1 d)
    (%primop :set-structure-slot state 2 high)
    (%primop :set-structure-slot state 3 low)
    (%primop :fixnum-logior
      (%primop :fixnum-shift-left (%primop :fixnum-logand high high-mask) 32)
      low)))

(defun random-fixnum-bits (count state)
  ;; The low COUNT bits are the same if we discard the excess high bits
  ;; before combining the words. Consume the high word first.
  (cond ((zerop count) 0)
        ((<= count 32)
         (%primop :fixnum-logand (random-word state)
                  (1- (%primop :fixnum-shift-left 1 count))))
        (t (random-word-pair state (1- (%primop :fixnum-shift-left 1 (- count 32)))))))

(defun random-bits (count state)
  "A random integer of COUNT bits."
  (when (<= 0 count 62)
    (return-from random-bits (random-fixnum-bits count state)))
  (let ((r 0) (n 0))
    (loop (when (>= n count) (return (ldb (byte count 0) r)))
          (setq r (logior (ash r 32) (random-word state)) n (+ n 32)))))

(defvar *random-state* (seeded-random-state 42))

(defun make-random-state (&optional state)
  (flet ((copy (s)
           (%make-random-state (random-state-a s) (random-state-b s)
                               (random-state-c s) (random-state-d s))))
    (cond ((null state) (copy *random-state*))
          ((eq state t)
           (seeded-random-state (logxor (get-universal-time) (get-internal-real-time))))
          ((random-state-p state) (copy state))
          (t (error 'type-error :datum state :expected-type '(or random-state boolean))))))

(declaim (inline random-unit-double))
(defun random-unit-double (state)
  (declare (optimize (safety 0)))
  (the double-float (%primop :double-fraction-53 (random-word-pair state #x1fffff))))

(defun random (limit &optional (state *random-state*))
  (cond ((and (%primop :double-float-p limit)
              (%primop :double-float-one-p limit))
         (random-unit-double state))
        ((and (integerp limit) (plusp limit))
         ;; 32 bits more than LIMIT has keep the bias of MOD negligible.
         (let ((count (+ (integer-length limit) 32)))
           (if (<= count 62)
               (%primop :fixnum-remainder (random-fixnum-bits count state) limit)
               (mod (random-bits count state) limit))))
        ((and (floatp limit) (plusp limit))
         (locally (declare (optimize (speed 3) (safety 0)))
           (if (%primop :double-float-p limit)
               (let ((bound (the double-float limit)))
                 (loop for value = (* bound (random-unit-double state))
                       when (< value bound) return value))
               (let ((bound (the single-float limit)))
                 (loop for value = (* bound (float (random-unit-double state) bound))
                       when (< value bound) return value)))))
        (t (error 'type-error :datum limit
                              :expected-type '(or (integer 1) (float (0.0)))))))
