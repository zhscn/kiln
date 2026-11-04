;;;; nontrivial-gray-streams, for Invistra: its Gray stream names are
;;;; Cyclosis' (docs/10 §18).

(defpackage #:nontrivial-gray-streams
  (:nicknames #:ngray)
  (:use)
  (:import-from #:cyclosis
                #:fundamental-character-output-stream #:stream-advance-to-column
                #:stream-clear-output #:stream-finish-output #:stream-force-output
                #:stream-fresh-line #:stream-line-column #:stream-line-length
                #:stream-terpri #:stream-write-char #:stream-write-string
                #:stream-start-line-p)
  (:export #:fundamental-character-output-stream #:stream-advance-to-column
           #:stream-clear-output #:stream-finish-output #:stream-force-output
           #:stream-fresh-line #:stream-line-column #:stream-line-length
           #:stream-terpri #:stream-write-char #:stream-write-string
           #:stream-start-line-p))
