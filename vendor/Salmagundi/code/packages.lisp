(cl:in-package #:common-lisp-user)

(defpackage #:salmagundi
  (:use #:common-lisp)
  ;; Shadow these for now.  Ultimately, import them with
  ;; the rest of the CL package. 
  ;; kiln: MAKE-HASH-TABLE and SXHASH, whose Salmagundi versions take a
  ;; client, and GETHASH and REMHASH: kiln's CL functions call the bucket
  ;; table's directly (lisp/target/clos/hash-tables.lisp). The others are
  ;; the CL functions (kiln has no other hash tables).
  (:shadow #+(not kiln) #:clrhash
           #:gethash
           #+(not kiln) #:hash-table
           #+(not kiln) #:hash-table-count
           #+(not kiln) #:hash-table-p
           #+(not kiln) #:hash-table-rehash-size
           #+(not kiln) #:hash-table-rehash-threshold
           #+(not kiln) #:hash-table-size
           #+(not kiln) #:hash-table-test
           #:make-hash-table
           #+(not kiln) #:maphash
           #:remhash
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
