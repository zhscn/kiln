# Vendored modules

Copies of SICL-ecosystem modules that kiln patches. Most are target code,
compiled into kiln's modules; Common-macros is a host library (kiln's
front end, in the host and in the compiler module) and Khazern and
Eclector are both (the host's LOOP and reader, and the image's). Host
libraries are found by ASDF before `deps/` (`tools/env.lisp`). Each is imported
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
| Khazern | https://github.com/s-expressionists/Khazern | b657262946bfba0e17ee930c58c8fcd6fa6be774 (2026-09-17) | BSD (`Khazern/LICENSE.md`) |
| Eclector | https://github.com/s-expressionists/Eclector | 1088a7998f0d205da12ff48de7238b1008a31792 (2026-08-29) | BSD (`Eclector/LICENSE`) |
| Anatomicl | https://github.com/s-expressionists/Anatomicl | f8279fb9dc303e12abe5a4e63a9e7bc7df586b98 | BSD (`Anatomicl/LICENSE.md`) |
| Ecclesia | https://github.com/s-expressionists/Ecclesia | 74027d0cedba9b98dce9611bf3ae2793e8819449 | BSD (`Ecclesia/LICENSE.md`) |
| Common-macros | https://github.com/robert-strandh/Common-macros | 4596ddf32357fa793ece25cecb6e8661259b51ac (2026-02-10) | no license file |
| Inravina | https://github.com/s-expressionists/Inravina | e28b107b025b2efdd4f16ed71fbdc0e1af62e478 (2026-07-11) | MIT (`Inravina/LICENSE.md`) |
| Maclina | https://github.com/s-expressionists/Maclina | a46ba99620ceb51f05f14e31d34fe77e1cfa96c1 (2026-09-15) | BSD (`Maclina/LICENSE`) |

## Clostrophilia patches

- Generic-function option conditions use private accessor names for the
  invalid declaration and method-combination values, keeping the CL
  symbols DECLARATION and METHOD-COMBINATION unbound as functions.

- A private `slot-object` root shares initialization between standard objects
  and array storage. Internal dispatch and layout access use physical classes;
  public array classification uses the built-in hierarchy.

- Long method combinations bind `:arguments` variables in effective methods,
  including supplied-p variables, `&whole`, and missing required arguments.
  `:generic-function` exposes the generic function to the expansion body.
  Argument binders are compiled with the definition and retain its lexical
  environment; effective methods interpret the resulting variable references.

- Generic-function reinitialization checks lambda-list congruence against
  installed methods before changing metadata.

- Class reinitialization updates superclass links only when direct superclasses
  were supplied; renaming and documentation changes preserve the layout.

- Effective methods check call arity and keyword arguments against the generic
  function and its applicable methods. Rest-only generic functions remain
  open; keyword functions use leftmost `:allow-other-keys` semantics. These
  checks apply on cache hits as well as misses.

- Standard initialization methods declare the keys they accept, rather
  than allowing every initarg. Kiln validates slot and applicable-method
  initargs after bootstrap, including constructor fast paths.

- `add-method` checks lambda-list congruence before changing either object
  and returns its generic function. Required and optional counts, rest/key
  acceptance and keyword names follow SBCL, including generic functions
  declaring `&allow-other-keys`.

- Slot reads and standard readers return only the primary value of
  `slot-unbound`, including cached and class-allocated slots.

- Direct `allocate-instance` calls finalize the class before reading its
  layout. `remove-method` returns its generic function and leaves methods
  attached to other generic functions alone.
- A missing slot returns through `slot-missing` rather than being passed
  to the slot-definition protocol. Setters supply the `setf` operation and
  new value; slot predicates and mutators preserve their required results.

- A single-dispatch discriminating closure is a fast closure that probes
  the cache for an instance's stamp and tail-calls the effective method
  (`%primop :tail-funcall-function`), and a slow closure for everything
  else; the closure wrapping a method's fast function tail-calls it. A
  double-dispatch closure is split the same way, and the list and
  automaton closures tail-call the effective method they find.

- Class `shared-initialize` preserves direct slots when the option is omitted,
  so reinitializing documentation or superclasses keeps the slot definitions.

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
  slot (an AST walker of the old front end set slots that way).
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
- Slot readers and writers: `spread-method-call` records the closure that
  reads or writes a local slot with its location in a direct-mapped table,
  and the discriminating closure of a one-parameter generic function (or a
  two-parameter generic function dispatching on its second parameter) caches
  the location instead of the closure, reading or writing the slot itself on
  a hit (an unbound slot on a read goes through the closure, which signals
  `slot-unbound`).
- Fast method functions that do not mention `call-next-method` or
  `next-method-p` take only the method's parameters without a `next-methods`
  parameter and are returned directly by `spread-method-call` without a
  wrapper closure; fast method functions that only call `(call-next-method)`
  or `(next-method-p)` with zero arguments (`:next-function`) receive the
  precomputed next-method function from `spread-method-call`.
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
- `default-discriminating-function` checks that the number of arguments is
  at least the number of required parameters before indexing into the
  argument list.
- The condition signaled by `slot-missing` is named `slot-missing-error`
  (upstream names the condition `slot-missing`, which makes `cl:slot-missing`
  name a class).

## Predicament patches

- Arithmetic conditions share a report that prints the operation and operands
  when an operation is provided. The operation defaults to NIL; default
  conditions remain printable while their operand slot is unbound.

- Simple conditions default their format arguments to `nil`. `error`,
  `signal` and `warn` accept function format controls through the condition
  coercion protocol; `warn` rejects conditions outside `warning`.
- `cerror` keeps condition objects' extra arguments for the continuation
  report and applies them individually to its format control.

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

- Array `equalp` hashes use active vector lengths and ignore storage element
  types. Hash-table content hashes combine entries independently of iteration
  order, with a depth budget for nested arrays and tables.

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
  loops when they grow. Standard-test tables are allocated directly by
  `make-bucket-hash-table` without `make-instance`, a symbol's `equal`
  hash is cached in its header identity-hash field, and `(setf gethash)`
  records the first tombstone slot while probing instead of probing a
  second time.

## Parcl patches

- Symbol lookup inherits only external symbols. Importing an already
  present symbol preserves its status; unexporting an accessible internal
  or inherited symbol succeeds. Export conflict checks honor shadowing
  symbols in the using package.
- `make-package` offers recovery for existing names and conflicting
  nicknames. Package deletion offers recovery for missing packages and
  packages still used by others.

- Public package mutators return `t` after completing their operations.
  Package designators are resolved with an explicit `package-error` when
  the package does not exist; invalid designator types signal `type-error`.
  `intern` accepts general strings and normalizes their active contents
  before creating a symbol.
- `shadowing-import` installs the chosen symbol directly, so an inherited
  symbol with the same name does not trigger the conflict checks of `import`.

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
- `map-symbols` keeps the names already visited in an `equal` hash
  table instead of a list searched for every inherited symbol (quadratic;
  5% of kiln compiling itself, which maps every package's symbols for each
  module).

## ctype patches

- `string` passes the client to `disjoin` (upstream omits it, so `string`
  parsed as the empty type).
- The `ctypep` method specialized on `complex` is not read under kiln
  (no complex numbers yet). `host.lisp`, `runtime.lisp` and
  `interface.lisp` are not loaded: kiln has its own client and interface
  (`lisp/target/clos/ctype-*.lisp`).

## Regalia patches

- Storage class selection uses kiln's canonical upgraded element types,
  including unsigned integer boundary types, fixnum, base-char, and NIL.


- Array storage inherits the private slot-object root and the public array
  hierarchy, keeping arrays outside `standard-object`.


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

- Character input peeking returns the unread buffer before consulting the
  underlying stream. String input positions exclude that buffered
  character; seeking discards it, and WITH-INPUT-FROM-STRING reports the
  logical next-character index.

- OPEN keeps the merged pathname as the stream's pathname, including
  logical components. The kiln file client translates it when accessing
  the physical file system.

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
- The default methods of `pathname` and `truename` on `t` are omitted under
  `#+kiln` (they call `(pathname (pathname stream-designator))`, which
  loops forever on non-pathname objects; kiln defines `cl:pathname` and
  `cl:truename` in `lisp/target/clos/pathnames.lisp`).

## Incless patches

- Readable pathname printing verifies that the namestring preserves
  components. Constructor syntax quotes the directory list when a
  namestring cannot represent those components.

- `define-interface` defines `kiln.kernel::%print-unreadable-object` under
  `#+kiln` so `cl:print-unreadable-object` can be defined early in
  `lisp/target/early.lisp` before `printer.lisp` is compiled. kiln's client
  (`lisp/target/clos/printer.lisp`) supplies the implementation-specific
  parts, and `lisp/target/clos/quaviver.lisp` the part of Quaviver that
  Incless uses.

## Invistra patches

Known upstream bug, not patched: `~F` rounds `(format nil "~,1f" 0.05f0)`
(and `0.05d0`) to `"0.0"`; it should be `"0.1"`, since both are slightly
greater than 0.05. Invistra with Quaviver does the same in SBCL.

Under `#+kiln`:

- `formatter` expands into a function that interprets the control string
  (the format compiler is target code, not available when macros are
  expanded). It parses the control string when creating the function and
  returns the unused arguments, including after an escape directive.
- `unique-name` is defined at compile time too (macro expanders call it).
- Infinities and NaNs are recognized through `quaviver:float-triple`.
- Output to a string with a fill pointer goes through a string output
  stream on it (upstream uses the string as the stream).
- `parse-control-string` caches the directives of each control string
  (by its contents); `format` interprets control strings at run time, and
  parsing was most of its cost.

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

- DOLIST and DOTIMES include their initializer in the implicit NIL block.
  DOLIST retains declarations in its result form, excluding type
  constraints on the iteration variable's final NIL binding.

- ETYPECASE reports the union of its clause types as the expected type,
  rather than a MEMBER type containing their names.

- `define-compiler-macro` returns its function name as one value after
  registering the expander, including `(setf name)` definitions.

- The `defgeneric-methods-form` client hook records embedded method objects
  for replacement on redefinition. The expansion uses a fresh generic-function
  variable so method bodies retain their defining lexical bindings.

- `defgeneric` checks duplicate and malformed options with `program-error`.
  Omitted class and method-combination options remain omitted in the client
  protocol so redefining a generic function preserves its existing choices.

- `typecase` treats `T` as an ordinary type, allowing later clauses; only
  `otherwise` must be last.

- `defmacro` returns the macro name. `define-modify-macro` passes the
  lexical environment to place expansion and evaluates modifier arguments
  before reading the place.
- Long-form `defsetf` binds fresh store symbols, uses temporaries for
  evaluated arguments, and preserves constant keyword names, lexical scope,
  declarations and the implicit named block. Generalized APPLY places call
  the accessor's SETF function with the stored arguments.

- Extra `defclass` options are quoted data. Singleton extra slot options
  are unwrapped, and repeated values use SBCL's ordering, so custom
  metaclasses and slot-definition classes receive their intended initargs.

- `defclass` rejects duplicate direct slot names and default initarg names.
  Repeated singleton slot options signal `program-error` and retain their
  slot specifier for condition reporting.

- `incf` and `decf` evaluate the delta after the place's subforms and
  before reading the place, preserving generalized-reference evaluation order.

- `handler-case` accepts an ordinary lambda list in its `:no-error`
  clause, while condition clauses retain their zero-or-one-variable rule.

- `remf` binds all place temporaries and evaluates the indicator before
  reading the property list, preserving generalized-place evaluation order.
- `ccase` and `ctypecase` return the selected clause's values from their
  retry loop. `ctypecase` reports the union of the accepted types.

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
- `Low/nth-value.lisp`: a constant index in `0..8` expands into `values`
  or `multiple-value-bind` instead of `multiple-value-list`.
- `Low/check-type.lisp`: the `store-value` restart is established in
  `check-type-error` (`lisp/target/clos/runtime-errors.lisp` on the
  target), called only when `typep` fails, so `check-type` makes no
  closure, variable cell or exit token on the hit path.
- `Low/handler-case.lisp`: a clause with an empty parameter list does not
  assign the condition to the outer variable, so the variable needs no
  cell when no clause binds it.

## Eclector patches

- Ordinary list CSTs match their child results in one traversal bounded
  by those results; dotted and cyclic expressions retain reconstruction. The
  outer node receives its source during construction instead of running
  `reinitialize-instance` after the list is built. Tail nodes keep their
  default source and the original raw cons identities.

- The `#S` construction protocol binds its input stream while calling the
  client, so invalid structure types and missing standard constructors
  signal reader errors associated with that stream.

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
- `read-token` accumulates characters into a reusable buffer
  (`*token-buffer*`) instead of allocating an adjustable vector per token,
  and `char-syntax-type` handles ASCII characters in the standard
  readtable inline before calling `eclector.readtable:syntax-type`.

## Inravina patches

- Eclector's backquote symbols (`eclector.reader:quasiquote`, `unquote`,
  `unquote-splicing`) are the quasiquote and unquote forms (`#+kiln`), in
  the types and in the standard dispatch table.

## Maclina patches

- STEP scopes instrument calls after callee and argument evaluation, using
  the shared source wrapper also used by the native compiler. Private
  compilation markers preserve lexical context and suppress instrumentation
  of the stepper and compile-time local macro expanders.

- MAKE-LOAD-FORM initializers that reference an active creation are deferred
  until its creator exists. Speculative initializer records use child
  coalescence tables and commit only on success, so retries cannot retain
  partially constructed constants. Genuine creation cycles signal
  PROGRAM-ERROR.

- The object writer canonicalizes an absent pathname host to NIL rather
  than an empty host name. The loader fills bytecode before asking the
  client to construct a module, allowing the client to convert or copy it.
  Container termination checks read binary EOF directly.

- CATCH transfers a thrown value to the value stack when its caller
  receives one value, while normal completion keeps its existing stack
  result. MULTIPLE-VALUE-CALL always pushes its function designator,
  including when the call's results are discarded.

- SYMBOL-MACROLET rejects constant and globally special names, and SPECIAL
  declarations for its own bindings. Inner free SPECIAL declarations and
  new variable bindings retain their lexical shadowing behavior.

- Both VMs implement long-operand stack-pointer save and restore, so local
  blocks work when their saved stack location exceeds 255.

- Unrecognized declaration identifiers signal style warnings. Global
  `declaration` proclamations are available through Trucler, so custom
  declarations are recognized without becoming type declarations.

- The native VM captures the values of a native `throw` caught by a
  bytecode `catch`, including when cleanup code calls back into the VM.

- The native VM advances past the operands of `encell` and the long
  closure creation and initialization instructions. Both VMs support long
  `encell` operands for captured mutable parameters beyond local slot 255.

- The VM's `throw` throws the values in its register (`vm-native.lisp`), not
  no values: a `catch` in native code (not the VM's) received `nil`
  (a macro function compiled by Maclina that throws to a `catch` in native
  code).
- `bytecode-call` tears down its frame in an `unwind-protect`: a non-local
  exit from the VM to native code (a `throw` or `return-from`) left the
  VM's stack, frame pointer and pc in the callee's frame, and later calls
  read garbage.
  For that, an exit to a block or tag of the VM (`exit-8`...) passes its
  target to the entry's function, which sets the pc (and the stack and
  frame pointers) once the `go` has unwound, after those cleanups.
- `called-fdefinition` on the target client calls
  `kiln.kernel::%called-fdefinition` so `fdefinition` itself can signal
  `undefined-function` when called directly while the VM still evaluates call
  arguments before signaling `undefined-function`.

## Ecclesia patches

- Macro and DEFTYPE lambda lists accept destructuring patterns after
  `&rest` and `&body`, including the empty pattern. Ordinary function
  lambda lists still require a variable there. Empty required patterns
  match only NIL.
- DESTRUCTURING-BIND accepts `&whole` patterns, including nested and
  dotted patterns. Its input form is evaluated once; whole-pattern
  matching and the remaining parameters share that value.

- DEFTYPE keyword parameters quote the implicit `*` default, matching the
  optional-parameter parser. Explicit initforms retain their evaluation
  semantics; ordinary destructuring continues to default to NIL.
- Destructuring recognizes `:allow-other-keys` as a legal key even when its
  leftmost value is NIL; that value still controls unknown-key acceptance.

## Anatomicl patches

- Typed structures require `:named` when requesting a predicate, and named
  vector structures require an element type that admits every symbol.
  Incompatible options signal `simple-error` during macro expansion.
