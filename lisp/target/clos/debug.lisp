;;;; Frames and backtraces (docs/17). The :FRAME primop is kiln_rt_frame
;;;; (rust/kiln-rt/src/debug.rs). A frame is named by a handle, a fixnum,
;;;; which is valid while the frame is on the stack. A frame's function
;;;; has a debug info object #(NAME FILE START END VARIABLES), lower.lisp.

(in-package #:kiln.kernel)

(defun kiln.sys:frame-list ()
  "Handles of the Lisp frames on the stack, innermost first: the first is
the frame of the caller of FRAME-LIST."
  (let ((fp (kiln.sys:%primop :frame-pointer))
        (size 64))
    (loop
      (let* ((v (make-array size))
             (n (kiln.sys:%primop :frame 0 fp v)))
        (when (<= n size)
          (return (coerce (subseq v 0 n) 'list)))
        (setf size n)))))

(defun frame-debug-info (frame)
  (kiln.sys:%primop :frame 1 frame nil))

(defun kiln.sys:frame-name (frame)
  "The name of the function of FRAME (NIL if unknown): a function name,
(FLET name :IN outer), (LAMBDA :IN outer), (METHOD name qualifiers...
specializers), (:TOP-LEVEL-FORM)."
  (let ((info (frame-debug-info frame)))
    (and info (svref info 0))))

(defun kiln.sys:frame-source (frame)
  "The source of FRAME's current call: the file's name, and the start and
end of the call form; or of the function's definition, without the call's
range. NIL if unknown."
  (let ((info (frame-debug-info frame))
        (start (kiln.sys:%primop :frame 2 frame nil))
        (end (kiln.sys:%primop :frame 3 frame nil)))
    (if info
        (values (svref info 1) (or start (svref info 2)) (if start end (svref info 3)))
        (values nil nil nil))))

(defun kiln.sys:frame-variables (frame)
  "An alist (NAME . VALUE) of the variables of FRAME whose values are
known during its current call (those live after it)."
  (let ((info (frame-debug-info frame))
        (n (kiln.sys:%primop :frame 4 frame nil)))
    (loop for i below n
          for name = (svref (svref info 4) (kiln.sys:%primop :frame 5 frame i))
          for value = (kiln.sys:%primop :frame 6 frame i)
          collect (if (consp name)
                      (cons (second name) (car value)) ; a cell
                      (cons name value)))))

(defun kiln.sys:frame-pc (frame)
  "The return address of FRAME's current call, and its offset in the
function's code."
  (values (kiln.sys:%primop :frame 7 frame nil)
          (kiln.sys:%primop :frame 8 frame nil)))

(defun kiln.sys:source-line (file position)
  "The line (from 1) and column (from 0, in characters) of POSITION, an
octet offset as source positions are (docs/17), in the UTF-8 file FILE,
or NIL."
  (handler-case
      (with-open-file (in file :element-type '(unsigned-byte 8))
        (let ((line 1) (column 0))
          (dotimes (i position (values line column))
            (let ((octet (read-byte in nil nil)))
              (cond ((null octet) (return nil))
                    ((= octet 10) (incf line) (setf column 0))
                    ;; Continuation octets are not characters.
                    ((/= (logand octet #xc0) #x80) (incf column)))))))
    (error () nil)))

(defun kiln.sys:print-frame (frame stream &key variables)
  (format stream "~S" (kiln.sys:frame-name frame))
  (multiple-value-bind (file start) (kiln.sys:frame-source frame)
    (when file
      (multiple-value-bind (line column) (and start (kiln.sys:source-line file start))
        (if line
            (format stream "  [~A:~D:~D]" file line column)
            (format stream "  [~A]" file)))))
  (when variables
    (loop for (name . value) in (kiln.sys:frame-variables frame)
          do (format stream "~%      ~S = ~S" name value))))

(defun kiln.sys:print-backtrace (&key (stream *error-output*) (frames (kiln.sys:frame-list))
                                      count variables)
  "Prints FRAMES (by default the frames of the caller and older ones),
at most COUNT of them, with their variables if VARIABLES is true."
  (loop for frame in frames
        for i from 0
        while (or (null count) (< i count))
        do (format stream "~&~3D: " i)
           (kiln.sys:print-frame frame stream :variables variables)
           (terpri stream)))

(defun debugger-frames ()
  "The frames of the computation that invoked the debugger: those older
than INVOKE-DEBUGGER's."
  (let* ((frames (kiln.sys:frame-list))
         (tail (member 'invoke-debugger frames :key #'kiln.sys:frame-name)))
    (if tail (rest tail) frames)))

(defun kiln.sys:exit (&optional (code 0))
  "Ends the process with the exit status CODE, after FINISH-OUTPUT on the
standard streams."
  (finish-output *standard-output*)
  (finish-output *error-output*)
  (sys 18 code))

;;; The default debugger: the program ends with the condition's report
;;; and a backtrace, unless KILN_BACKTRACE is 0.
(defun kiln-backtrace-debugger (condition)
  (handler-case
      (progn
        (format *error-output* "~&kiln: unhandled ~S: ~A~%"
                (class-name (class-of condition)) condition)
        (unless (equal (sys-string 10 (string-octets "KILN_BACKTRACE")) "0")
          (format *error-output* "Backtrace:~%")
          (kiln.sys:print-backtrace :frames (debugger-frames) :count 30 :variables t))
        (kiln.sys:exit 1))
    (error ()
      (clostrophilia::kiln-default-debugger condition))))

(setf predicament::*default-debugger* 'kiln-backtrace-debugger)
