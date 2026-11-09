;;;; Clocks, Gregorian calendar conversion, and local timezone lookup.

(in-package #:kiln.kernel)

(defconstant internal-time-units-per-second 1000000)

(defun get-internal-real-time () (sys 14))

(defun get-internal-run-time () (sys 16))

(defun get-universal-time ()
  ;; Universal time of 1970-01-01T00:00:00Z.
  (+ (sys 15) 2208988800))

;;; Sleeping blocks garbage collection by other threads; there are none
;;; yet.
(defun sleep (seconds)
  (check-type seconds (real 0))
  (sys 17 (round (* seconds 1000000)))
  nil)


(defun calendar-days-before-year (year)
  (let ((previous (1- year)))
    (- (+ (* previous 365) (floor previous 4)
          (- (floor previous 100)) (floor previous 400))
       693595)))

(defun calendar-leap-year-p (year)
  (and (zerop (mod year 4))
       (or (not (zerop (mod year 100))) (zerop (mod year 400)))))

(defun calendar-month-days (month year)
  (if (= month 2)
      (if (calendar-leap-year-p year) 29 28)
      (if (member month '(4 6 9 11)) 30 31)))

(defun timezone-unix-second (universal-time)
  (let ((unix (- universal-time 2208988800)))
    (if (<= (- (expt 2 31)) unix (1- (expt 2 31)))
        unix
        (let ((offset (- universal-time 3160857600)))
          ;; Preserve the March-based year offset used by SBCL outside time_t32.
          (dolist (period '((12622780800 nil) (3155673600 3)
                            (126230400 25) (31536000 3)))
            (let ((count (truncate offset (first period))))
              (when (second period) (setf count (min count (second period))))
              (decf offset (* count (first period)))))
          (+ offset (if (minusp unix) -2109283200 2056320000))))))

(defun local-timezone (universal-time)
  (let* ((unix (timezone-unix-second universal-time))
         (seconds-west (sys 19 unix 0))
         (daylight (sys 19 unix 1)))
    (when (minusp daylight)
      (error "Cannot determine local timezone: ~A" (errno-message (- daylight))))
    (values seconds-west (plusp daylight))))

(defun decode-universal-time (universal-time &optional time-zone)
  (check-type universal-time (integer 0))
  (when time-zone (check-type time-zone (rational -24 24)))
  (multiple-value-bind (seconds-west daylight)
      (if time-zone (values (* time-zone 3600) nil)
          (local-timezone universal-time))
    (check-type seconds-west integer)
    (multiple-value-bind (days seconds) (floor (- universal-time seconds-west) 86400)
      (let* ((year (+ 1900 (floor (* days 400) 146097)))
             (month 1))
        (loop while (< days (calendar-days-before-year year)) do (decf year))
        (loop while (>= days (calendar-days-before-year (1+ year))) do (incf year))
        (let ((date (- days (calendar-days-before-year year))))
          (loop while (>= date (calendar-month-days month year))
                do (decf date (calendar-month-days month year)) (incf month))
          (multiple-value-bind (hour rest) (floor seconds 3600)
            (multiple-value-bind (minute second) (floor rest 60)
              (values second minute hour (1+ date) month year (mod days 7)
                      daylight (or time-zone (+ (/ seconds-west 3600)
                                                (if daylight 1 0)))))))))))

(defun get-decoded-time ()
  (decode-universal-time (get-universal-time)))

(defun encode-universal-time (second minute hour date month year &optional time-zone)
  (check-type second (integer 0 59))
  (check-type minute (integer 0 59))
  (check-type hour (integer 0 23))
  (check-type date (integer 1 31))
  (check-type month (integer 1 12))
  (check-type year (or (integer 0 99) (integer 1899)))
  (when time-zone (check-type time-zone (rational -24 24)))
  (when (< year 100)
    (let* ((current (nth-value 5 (get-decoded-time)))
           (guess (+ year (* 100 (truncate (- current 50) 100)))))
      (setf year (if (> (- current guess) 50) (+ guess 100) guess))))
  (let ((days (+ (calendar-days-before-year year) (1- date))))
    (dotimes (index (1- month))
      (incf days (calendar-month-days (1+ index) year)))
    (let ((time (+ second (* minute 60) (* hour 3600) (* days 86400))))
      (let ((encoded
              (if time-zone
                  (+ time (* time-zone 3600))
                  (let* ((offset (local-timezone (* (floor time 3600) 3600)))
                         (guess (+ time offset)))
                    (+ time (local-timezone guess))))))
        (check-type encoded (integer 0))
        encoded))))
