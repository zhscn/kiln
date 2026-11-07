;;;; Random numbers (CLHS 12.1.7): RANDOM, *RANDOM-STATE*,
;;;; MAKE-RANDOM-STATE. A random state is a structure holding Marsaglia's
;;;; xorshift128 generator: four 32-bit words, so all its arithmetic is on
;;;; fixnums. Not cryptographic; the same seed gives the same sequence.

(in-package #:kiln.kernel)

(defstruct (random-state (:constructor %make-random-state (a b c d))
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

(defun random-word (state)
  "The next 32 random bits of STATE."
  (let* ((x (random-state-a state))
         (w (random-state-d state))
         (tt (logxor x (logand (ash x 11) #xFFFFFFFF))))
    (setf (random-state-a state) (random-state-b state)
          (random-state-b state) (random-state-c state)
          (random-state-c state) w
          (random-state-d state) (logxor w (ash w -19) tt (ash tt -8)))))

(defun random-bits (count state)
  "A random integer of COUNT bits."
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

(defun random (limit &optional (state *random-state*))
  (cond ((and (integerp limit) (plusp limit))
         ;; 32 bits more than LIMIT has keep the bias of MOD negligible.
         (mod (random-bits (+ (integer-length limit) 32) state) limit))
        ((and (floatp limit) (plusp limit))
         (loop (let ((r (* limit (float (/ (random-bits 53 state) (ash 1 53)) limit))))
                 (when (< r limit) (return r)))))
        (t (error 'type-error :datum limit
                              :expected-type '(or (integer 1) (float (0.0)))))))
