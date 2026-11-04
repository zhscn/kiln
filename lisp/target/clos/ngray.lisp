;;;; nontrivial-gray-streams, for Inravina and Invistra: its Gray stream
;;;; names are Cyclosis' (docs/10 §18). STREAM-ELEMENT-TYPE and
;;;; STREAM-EXTERNAL-FORMAT are the CL generic functions.

(defpackage #:nontrivial-gray-streams
  (:nicknames #:ngray)
  (:use)
  (:import-from #:cyclosis
                #:fundamental-character-output-stream #:stream-advance-to-column
                #:stream-clear-output #:stream-finish-output #:stream-force-output
                #:stream-fresh-line #:stream-line-column #:stream-line-length
                #:stream-terpri #:stream-write-char #:stream-write-string
                #:stream-start-line-p #:stream-element-type #:stream-external-format
                #:stream-line-length)
  (:export #:fundamental-character-output-stream #:stream-advance-to-column
           #:stream-clear-output #:stream-finish-output #:stream-force-output
           #:stream-fresh-line #:stream-line-column #:stream-line-length
           #:stream-terpri #:stream-write-char #:stream-write-string
           #:stream-start-line-p #:stream-element-type #:stream-external-format
           #:stream-line-length))
