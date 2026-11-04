(cl:in-package #:common-lisp-user)

(defpackage #:salmagundi
  (:use #:common-lisp)
  ;; Shadow these for now.  Ultimately, import them with
  ;; the rest of the CL package. 
  ;; kiln: only MAKE-HASH-TABLE and SXHASH, whose Salmagundi versions take
  ;; a client; the others are the CL functions (kiln has no other hash
  ;; tables).
  (:shadow #+(not kiln) #:clrhash
           #+(not kiln) #:gethash
           #+(not kiln) #:hash-table
           #+(not kiln) #:hash-table-count
           #+(not kiln) #:hash-table-p
           #+(not kiln) #:hash-table-rehash-size
           #+(not kiln) #:hash-table-rehash-threshold
           #+(not kiln) #:hash-table-size
           #+(not kiln) #:hash-table-test
           #:make-hash-table
           #+(not kiln) #:maphash
           #+(not kiln) #:remhash
           #:sxhash)
  (:export #:ceiling-pow2
           #:clrhash
           #:compute-hash
           #:default-hash-function
           #:define-interface
           #:define-hash-table-test
           #:eq-hash
           #:eql-hash
           #:equal-hash
           #:equalp-hash
           #:gethash
           #:hash
           #:hash-table
           #:hash-table-count
           #:hash-table-hash-function
           #:hash-table-offset
           #:hash-table-p
           #:hash-table-rehash-size
           #:hash-table-rehash-threshold
           #:hash-table-size
           #:hash-table-test
           #:make-hash
           #:make-hash-table
           #:make-hash-table-iterator
           #:maphash
           #:mod-pow2
           #:rehash
           #:rehash-p
           #:remhash
           #:standard-client))
