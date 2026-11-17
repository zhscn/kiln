;;;; Run after tools/env.lisp, (ql:quickload "kiln") and tools/test-mir.lisp.
(in-package #:kiln.compiler)

(assert (eq (hir-constant-type (ash 1 100)) 'unsigned-byte))
(assert (not (hir-fixnum-type-p 'unsigned-byte)))
(assert (not (hir-known-subtype-p 'unsigned-byte '(integer 0 255))))
(assert (eq (hir-type-join 'unsigned-byte '(integer -1 -1)) 'integer))
(assert (equal '(t) (mir-test-checks '(the unsigned-byte 0))))
(assert (equal '(nil t) (mir-test-checks
                        '(the unsigned-byte (1+ (the unsigned-byte (mir-unknown)))))))
(assert (equal '(nil nil) (mir-test-checks
                          '(the unsigned-byte (1- (the unsigned-byte (mir-unknown)))))))
(assert (equal '(nil nil) (mir-test-checks
                          '(the (unsigned-byte 8) (the unsigned-byte (mir-unknown))))))
(assert (equal '(t) (mir-test-checks
                    '(let ((n 0))
                       (tagbody again (incf n) (when (mir-unknown) (go again)))
                       (the unsigned-byte n)))))
(assert (equal '(nil) (mir-test-checks
                      '(let ((n 0))
                         (tagbody again (decf n) (when (mir-unknown) (go again)))
                         (the unsigned-byte n)))))
(format t "Unsigned facts survive positive growth without implying a finite width or accepting negative growth.~%")
