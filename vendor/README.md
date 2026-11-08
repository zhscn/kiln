# Vendored modules

Copies of SICL-ecosystem modules that kiln patches. Most are target code,
compiled into kiln's modules; Common-boot and Common-macros are host
libraries (kiln's front end) and Khazern and Eclector are both (the
host's LOOP and reader, and the image's), as are parser.packrat,
s-expression-syntax and Iconoclast (the front end's, in the host and in the compiler
module). Host libraries are found by ASDF before `deps/` (`tools/env.lisp`). Each is imported
unmodified in its own commit (the upstream commit is recorded below), and
kiln's changes follow in separate commits, so `git log -- vendor/NAME`
shows exactly what kiln changed. Changes are not sent upstream for now.

| Module | Upstream | Commit | License |
|---|---|---|---|
| Clostrophilia | https://github.com/robert-strandh/Clostrophilia | 9d0e86c734bdba3e6c009b8cab222c2d0e81f29b (2026-08-29) | BSD (`Clostrophilia/LICENSE-BSD`) |
| Salmagundi | https://github.com/s-expressionists/Salmagundi | f03296d46a1b189a3b723eb2dcdfc7c5af38163a (2025-09-25) | BSD (`Salmagundi/LICENSE-BSD`) |
| Predicament | https://github.com/robert-strandh/Predicament | 715b3ae57ac8aa9b7ff07eb5ad864485d29aacbd (2025-06-02) | `Predicament/LICENSE.text` |
| Parcl | https://github.com/s-expressionists/Parcl | bec1c13abb9f77deecf44f2e9a37b99be962e783 (2025-06-04) | BSD (`Parcl/LICENSE`) |
| ctype | https://github.com/s-expressionists/ctype | 554b725de79ed170ca1452a7562950ecdeac5a47 (2026-06-23) | BSD (`ctype/LICENSE`) |
| Regalia | https://github.com/s-expressionists/Regalia | 76b2f27f521edf072f8c9012e714caed3fed2194 (2026-06-04) | BSD (`Regalia/LICENSE.text`) |
| Cyclosis | https://github.com/s-expressionists/Cyclosis | c918406b78a6e450d4543fe7bff0ff443f4c6641 (2026-06-22) | BSD (`Cyclosis/LICENSE-BSD`) |
| Incless | https://github.com/s-expressionists/Incless | 28587a456142ef16c1e6d71297fc681387186953 (2026-07-11) | BSD (`Incless/LICENSE.md`) |
| Invistra | https://github.com/s-expressionists/Invistra | 1585d04b1b1fc3b6e042de30b7785fe877ae4e2e (2026-06-22) | BSD (`Invistra/LICENSE.md`) |
| Common-boot | https://github.com/robert-strandh/Common-boot | d4270d0fe1c8e8d5708f7f8980c5454d7d35ee95 (2025-10-13) | no license file |
| Khazern | https://github.com/s-expressionists/Khazern | b657262946bfba0e17ee930c58c8fcd6fa6be774 (2026-09-17) | BSD (`Khazern/LICENSE.md`) |
| Eclector | https://github.com/s-expressionists/Eclector | 1088a7998f0d205da12ff48de7238b1008a31792 (2026-08-29) | BSD (`Eclector/LICENSE`) |
| Common-macros | https://github.com/robert-strandh/Common-macros | 4596ddf32357fa793ece25cecb6e8661259b51ac (2026-02-10) | no license file |
| Inravina | https://github.com/s-expressionists/Inravina | e28b107b025b2efdd4f16ed71fbdc0e1af62e478 (2026-07-11) | MIT (`Inravina/LICENSE.md`) |
| parser.packrat | https://github.com/scymtym/parser.packrat (branch `future`) | 835090176480e68a8af87ba550b6c9639f94f542 (2023-04-04) | MIT (`parser.packrat/COPYING`) |
| s-expression-syntax | https://github.com/scymtym/s-expression-syntax (branch `beach`) | 1ecd399a671eeb34a50e573a38d74c4dab3663b1 (2024-04-10) | MIT (`s-expression-syntax/COPYING`) |
| Maclina | https://github.com/s-expressionists/Maclina | a46ba99620ceb51f05f14e31d34fe77e1cfa96c1 (2026-09-15) | BSD (`Maclina/LICENSE`) |
| Iconoclast | https://github.com/robert-strandh/Iconoclast | 1ec145e113c3f0342823816b5fd8644ae9c23222 (2025-07-20) | no license file |

## Clostrophilia patches

Each patched place is marked with a `kiln:` comment.

- When the classes of the arguments do not determine the applicable
  methods (EQL specializers), the effective method is cached by the
  classes and the EQL objects; upstream computes it at each call. The
  cache is emptied by `invalidate-discriminating-function`.
- `automaton-transition` (kiln's interpreter of the dispatch automaton)
  uses open-coded fixnum operations, and the stamps of instances are read
  directly.

- `*class-unique-number*` is a `defvar`: the bootstrap numbers the braid's
  classes before `initialize-instance-defmethods.lisp` is loaded.
- The `(setf documentation)` of `add-method` is not evaluated
  (Clostrophilia's `documentation` takes one object; no `format` yet).
- No `compile` at run time (kiln has no compiler at run time before M5):
  the discriminating function interprets the discriminating automaton
  (binary search over stamp intervals per layer) instead of compiling a
  `tagbody`; effective method forms are interpreted into closures
  (`call-method`, `make-method`, `progn`, `multiple-value-prog1`, `if`,
  `quote`, `and`, `or` and calls to global functions); accessor method
  functions are closures.
- `default-discriminating-function` checks for obsolete instances (stamp
  differs from the class's unique number) and updates them before
  dispatching again, as its comment describes.
- A miss does not remake the discriminating function each time (upstream
  adds every call cache of the call history to a new automaton at each
  miss: with N call caches, N misses cost N^3). A miss whose classes have
  a call cache calls its effective method; the discriminating function is
  remade once the misses since it was made reach a quarter of the call
  history it was made from (or that history was short). The call cache
  of the classes is looked up comparing the classes with `eq` (upstream
  `equal`).
- `shared-initialize-aux` checks `slot-names` before calling
  `slot-boundp-using-class` and `slot-definition-initfunction`, and reads a
  slot's initargs only when there are initargs: `reinitialize-instance`
  (`slot-names` NIL) with one initarg made three generic function calls per
  slot (Iconoclast's AST walker sets slots that way).
- A generic function that dispatches on one or two of its spread
  parameters, without EQL specializers, has a discriminating closure that
  remembers the stamps of the last call's arguments and its effective
  method, and calls it again without walking the automaton.
- Method functions are called with the generic function's arguments
  unchanged: upstream appends `:allow-other-keys t` for a method with
  keyword parameters, which its `&rest` parameter then sees
  (architecture.builder-protocol stores such a list). kiln's method lambdas
  have `&allow-other-keys` instead (`lisp/macro-client.lisp`).
- The storage of a slot with `:allocation :class` starts unbound
  (upstream: `nil`, so its initform was never used).
- The standard method combination does not require primary methods: an
  effective method without them signals an error only if the primary
  methods are reached (an `:around` method need not call
  `call-next-method`; Predicament's `signal` on a symbol relies on it).

- Clients can interpret more operators in effective method forms
  (`*effective-method-operators*`; kiln's ctype client adds `surely`).
- The discriminating closures of generic functions that dispatch on one or
  two (spread) parameters have a direct-mapped cache of (stamps function)
  entries, indexed by the low bits of the stamps and sized from the call
  history (4 to 256 entries), instead of a one-entry cache; a miss takes
  the automaton in a separate function (`single-dispatch-miss`,
  `double-dispatch-miss`), so that the hit path needs no large frame.
  Generic functions with `&optional`, `&rest` or `&key`
  parameters that dispatch on one parameter have the same cache
  (`make-single-dispatch-list-closure`; they took the automaton at every
  call).
- `slot-value` and `(setf slot-value)` of a standard instance of a class
  whose metaclass is `standard-class` read and write the slot's location
  from the cache of `%slot-location` (`fast-slot-location`, kiln's
  `support.lisp`), as accessor methods do.
- `eql-dispatch-lookup` moves the entry it finds to the front of the EQL
  dispatch cache's list: the builder protocol's `relate`, with EQL
  specializers on dozens of relation kinds, scanned the whole list at
  every call (3.5% of kiln compiling itself).
- Slot readers: `spread-method-call` records the closure that reads a
  local slot with its location in a direct-mapped table, and the
  discriminating closure of a one-parameter generic function caches the
  location instead of the closure, reading the slot itself on a hit (an
  unbound slot goes through the closure, which signals `slot-unbound`).
- Effective methods of the standard method combination's shapes (`progn`,
  `multiple-value-prog1`, `call-method`, `make-method`) whose methods have
  fast functions become closures of the spread arguments
  (`spread-form-closure`), and a `make-method` next method gets a fast
  function too, for `call-next-method` from an `:around` method. Only a
  bare `call-method` did before; two primary methods (a specific one and
  a default one) make a `multiple-value-prog1` form, so most calls of the
  compiler's generic functions consed their arguments and interpreted the
  form.
- `argument-stamp` reads a native structure's stamp from its layout
  inline, as it reads a standard instance's from its rack (it went
  through `stamp` out of line).

## Predicament patches

- `signal` and `warn` on a string or a symbol call themselves on the condition without
  a stray `nil` argument (which its own `:before` method rejected).
- Under `#+kiln`, the reports of `error`, `parse-error`, `program-error`,
  `control-error`, `reader-error`, `warning`, `style-warning` and
  `storage-condition`, which ignore the condition, are not defined: they
  took precedence over the reports of classes later in a subclass's
  precedence list (Khazern's conditions are `parse-error`s and
  `acclimation:condition`s).

- `style-warning` is a `warning` (upstream: a direct subclass of
  `condition`), and `reader-error` a `parse-error` and a `stream-error`
  (upstream: an `error`), as in CLHS. kiln loads `reader-error` after
  `stream-error`.
- `abort`, `muffle-warning`, `continue`, `store-value` and `use-value`
  test whether the restart was found (upstream tests the optional
  condition, so `(abort)` always signalled a `control-error`).

## Salmagundi patches

Under `#+kiln` (kiln reads target sources with its own features):

- The package shadows only `make-hash-table` and `sxhash` (their
  Salmagundi versions take a client); `gethash` and the rest are the CL
  functions.
- `eq-hash` uses kiln's identity hash (stored in the object header,
  stable across moving collections); `slot-names` uses Clostrophilia;
  `hash-float` hashes the exact rational value instead of using Quaviver.
- `hash-hash-table` refers to its parameter `object`, not an undefined
  `table` (an upstream bug).
- `gethash` and `remhash` are shadowed too: kiln's `cl:gethash`,
  `(setf cl:gethash)` and `cl:remhash` call the bucket table's functions
  directly and Salmagundi's generic functions otherwise
  (`lisp/target/clos/hash-tables.lisp`).
- The bucket hash table keeps what lookups need in one simple vector (its
  core), read at a fixed location in the instance, and compares with
  `eq`, `eql` and `equal` inline: upstream calls several accessors and
  `assoc` with the test at each lookup.
- The bucket hash table iterates in the order SBCL's hash tables do:
  insertion order, a removed entry's place reused by the next insertion
  (the last freed first). An entry is `(key value . index)` in the buckets
  and in an insertion-ordered vector. Upstream iterates bucket by bucket,
  in the order of the keys' hashes (identity hashes: different in every
  run). Macro expanders iterate over hash tables (Khazern's destructuring
  temporaries), and kiln compiling kiln must make SBCL's KIR.
- The table is no longer made of buckets (the class keeps its name): it
  is open addressing, as CPython's dict. The entries are in three vectors
  (keys, values, hashes) in iteration order; an index vector, a power of
  two long and at most half used, maps a hash to an entry by linear
  probing, comparing the stored hashes first. Nothing is allocated per
  entry; the vectors double when full (the rehash size and threshold are
  hints, CLHS `make-hash-table`). The vectors are allocated with kiln's
  primitive (`kiln.kernel::make-simple-vector`) and copied with plain
  loops when they grow.

## Parcl patches

Loaded intrinsically (`parcl-low`, `parcl-low-class`, the `parcl`
functions); under `#+kiln`:

- `parcl-low-class` does not shadow `package`: its package class is
  `cl:package`.
- `use-packages` is rewritten: upstream computes the added packages the
  wrong way round, takes a symbol accessible through two packages for a
  conflict, ignores shadowing symbols and does not update the used-by
  lists. The `conflicts` condition is a `package-error` (it had no
  superclass, so it was not an error), and its report takes a list.
- `unuse-package` updates the used-by list; the `parcl` function is named
  `unuse-package` (upstream: `unuse-pacakge`).
- `import` gives a symbol without a home package the package as its home.
- `unintern` returns true.

## ctype patches

- `string` passes the client to `disjoin` (upstream omits it, so `string`
  parsed as the empty type).
- The `ctypep` method specialized on `complex` is not read under kiln
  (no complex numbers yet). `host.lisp`, `runtime.lisp` and
  `interface.lisp` are not loaded: kiln has its own client and interface
  (`lisp/target/clos/ctype-*.lisp`).

## Regalia patches

Under `#+kiln` (simple vectors and strings stay native):

- The package shadows the CL array names (`array`, `vector`, `string`,
  `make-array`, `aref`, ...): kiln defines the CL functions.
- `array` has `standard-object` and `cl:array` as superclasses, and slots
  for the native vector holding the elements and the adjustable flag;
  `vector`, `string` and `bit-vector` also have the CL classes of those
  names as superclasses.
- `vector-unsigned-byte-16.lisp` defines `vector-unsigned-byte-16`
  (upstream: a second `vector-unsigned-byte-32`); the vector class for
  bits is `bit-vector` (upstream: the undefined `vector-bit`).

## Cyclosis patches

Under `#+kiln`:

- The package does not shadow the names whose definitions in Cyclosis are
  the CL ones (`stream`, `close`, `streamp`, the stream classes, ...), and
  the intrinsic interface does not `shadowing-import` and `export` them
  at run time: kiln reads the sources into the host's packages, and its
  run-time packages mirror those. The package for the interface is a
  name, not a package object.
- The macro expansion helpers are defined at compile time too
  (`eval-when`).
- POSIX file streams read and write octets through kiln's runtime.
- `stream-advance-to-column` writes spaces (upstream: newlines).
- UTF-8: three octets encode the codes below `#x10000` (upstream:
  `#x1000`); decoding shifts the octets' bits left (upstream: right).
- A string output stream's string grows geometrically (upstream: by 32
  elements, which makes writing quadratic).
- A string output stream appends a character without going through
  `(setf stream-file-position)` and its methods, and has its own
  `stream-write-string`, which appends the string at once (upstream: one
  `stream-write-char` per character).

## Incless patches

None. kiln's client (`lisp/target/clos/printer.lisp`) supplies the
implementation-specific parts, and `lisp/target/clos/quaviver.lisp` the
part of Quaviver that Incless uses.

## Invistra patches

Known upstream bug, not patched: `~F` rounds `(format nil "~,1f" 0.05f0)`
(and `0.05d0`) to `"0.0"`; it should be `"0.1"`, since both are slightly
greater than 0.05. Invistra with Quaviver does the same in SBCL.

Under `#+kiln`:

- `formatter` expands into a function that interprets the control string
  (the format compiler is target code, not available when macros are
  expanded); it returns NIL instead of the unused arguments.
- `unique-name` is defined at compile time too (macro expanders call it).
- Infinities and NaNs are recognized through `quaviver:float-triple`.
- Output to a string with a fill pointer goes through a string output
  stream on it (upstream uses the string as the stream).
- `parse-control-string` caches the directives of each control string
  (by its contents); `format` interprets control strings at run time, and
  parsing was most of its cost.

## Common-boot patches

- The HIR evaluator compiles the argument parser of each function it
  evaluates (`HIR-evaluator/parse-arguments-instruction.lisp`) with
  Maclina on kiln, not the native `compile` (`kiln.kernel::*compile-function*`
  bound to `nil`): cross compilation evaluates a function for
  every macro, about 800 of them for the kernel and CLOS, and the native
  compiler took longer for each than the parser ever runs.
- The form of `load-time-value` is converted in a lexical environment
  with only the global environment (upstream: the global environment
  itself, in which a `lambda` form cannot add its local functions and
  variables).
- The names in the declarations of a function body with a lambda list
  are finalized into references, as `let`'s are (upstream leaves them
  names, which Iconoclast's splitting of `let*` rejects when a lambda
  list with `&optional` is lexified).
- `augment-environment-with-binding-variable` returns the environment
  unchanged for a globally special variable (upstream: NIL, which `let*`
  then used as the environment of the following bindings and the body).

## Khazern patches

- No complexes or pathnames among the initial values of accumulation
  variables, and no complex numeric types (kiln has neither yet):
  `#-kiln`.
- `constant-form-p` instead of `constantp`: only self-evaluating objects,
  constant variables and `quote` forms are constant. SBCL's `constantp`
  also folds calls of pure functions (`(integer-length
  most-positive-fixnum)`), kiln's does not, and LOOP expanded differently
  in the host and on kiln (`for i below FORM` binds FORM to a variable or
  not).

## Common-macros patches

- `defclass`: a slot specifier that is a symbol is canonicalized into the
  form `(list :name 'slot)` (upstream: `(:name 'slot)`, which is then
  evaluated as a call of `:name`). Khazern has such a slot.
- `Low/utilities.lisp`: the definitions that only the extrinsic system
  uses (`transform-name`, `macro-function`, `macro-function-exists-p`,
  `defmacro`, `macroexpand-1`) are read only `#-kiln`. kiln's target
  compiles the macros in its own package `kiln.cmd` (it uses CL and shadows
  only `get-setf-expansion`, `ensure-generic-function` and `proclaim`),
  where these would redefine CL's functions. Upstream's intrinsic package
  shadows too little for the same files: `get-setf-expansion` taking a
  client would become CL's.
- `define-modify-macro`: the expansion binds the place's temporaries and
  the store variable with `let*` (upstream `let`: the new value's form,
  which reads the place, referred to unbound temporaries).
- `Low/utilities.lisp`: the extrinsic `macroexpand-1` calls the macro's
  expander with the environment (upstream calls the host's
  `macroexpand-1` without it, so local macros and symbol macros were
  invisible to the expanders: `(setf (m) x)` with `m` a local macro became
  a call of `(setf m)`).

## Eclector patches

- The class of simple readtables has the built-in class `cl:readtable` as
  a superclass too (with `standard-object`).
- The replacement for a bad `#P` is `(pathname ".")`, not the literal
  `#P"."` (no pathname constants in kiln's compiled code).
- A backquoted list ending in `,@x` has `x` as its tail, as SBCL's
  backquote makes it: `(append ... x)`, not `(append ... x 'nil)`, which
  copies `x`. Macro expanders compiled by SBCL (in the host) and by kiln
  from Eclector's expansion (on kiln) then make expansions with the same
  shared structure, and so the same constants in the KIR.
- For the same reason, the parts of a backquoted template without unquotes
  are quoted, as SBCL quotes them: a sublist (`` `(if (null x) ,y) `` is
  `(append (list 'if) (list '(null x)) (list y))`) and a tail
  (`` `(a ,x b c) `` ends in `'(b c)`, shared). Each expansion has the
  same constant parts.

## Inravina patches

- Eclector's backquote symbols (`eclector.reader:quasiquote`, `unquote`,
  `unquote-splicing`) are the quasiquote and unquote forms (`#+kiln`), in
  the types and in the standard dispatch table.

## parser.packrat patches

- `%uses?` and `%uses-position?` (`src/grammar/base/compiler.lisp`) use
  `sb-cltl2:macroexpand-all`; on kiln (`#+kiln`) they compile the form
  with `compile` (Maclina's), which expands its macros as
  `macroexpand-all` does, and so decide as SBCL does (the generated parser,
  and so the KIR of the compiler module compiled on kiln, are SBCL's). A
  form that does not compile counts as using a name that occurs anywhere
  in it. They compile with Maclina even after the
  compiler module makes `compile` native (`kiln.kernel::*compile-function*`
  bound to `nil`): the native compiler does not compile
  `macrolet` that is not at top level, and the fallback decided
  differently from SBCL.

## s-expression-syntax patches

- `constant?` (`code/definitions/names.lisp`) uses `constantp` on kiln
  instead of `sb-cltl2:variable-information`.
- `pprint-logical-block`'s syntax (`code/definitions/io-macros.lisp`) spelled
  `suffix` with the ligature ﬃ (U+FB03) where it binds the variable, so
  the node referred to an unbound `suffix` (SBCL only warns).

## Maclina patches

- The VM's `throw` throws the values in its register (`vm-native.lisp`), not
  no values: a `catch` in native code (not the VM's) received `nil`
  (`%uses?` of parser.packrat on kiln throws from a macro function compiled
  by Maclina to a `catch` in native code).
- `bytecode-call` tears down its frame in an `unwind-protect`: a non-local
  exit from the VM to native code (a `throw` or `return-from`) left the
  VM's stack, frame pointer and pc in the callee's frame, and later calls
  read garbage.
  For that, an exit to a block or tag of the VM (`exit-8`...) passes its
  target to the entry's function, which sets the pc (and the stack and
  frame pointers) once the `go` has unwound, after those cleanups.

## Iconoclast patches

- The AST walker's `set-slot` (`Code/AST-walker/ast-walker.lisp`) sets the
  slot whose initarg is the reader's keyword with `slot-value`, the slot's
  name found once for each class and reader (closer-mop, now a dependency
  of the system), instead of interning the keyword and calling
  `reinitialize-instance` on every call. That is what
  `reinitialize-instance` does, no AST class having methods on it or on
  `shared-initialize`; on kiln, which runs `set-slot` for every slot of
  every node in each pass of the AST transformations, it took a third of
  the time of compiling.
- The walk of a node follows a plan made once per class (`walk-plan`): the
  cardinality, reader and slot name of each slot designator.
  `slot-designators` has the `append` method combination, so every call
  made a new list; a slot is now written only when its child changed.
- `compute-ast-info` (`Code/AST-transformations/compute-ast-info.lisp`)
  finds the parents, owners and function tree in one walk, which also
  lists the local functions in the order the walk finishes them, then
  computes the escaped functions and the call graph from that list,
  instead of five walks (one each in `compute-parent-asts`,
  `compute-owner-asts`, `compute-function-tree`,
  `compute-escaped-functions` and `compute-call-graph`, which are still
  defined). The result is the same, entry for entry and in the same
  order. It runs three times for each top-level form.
