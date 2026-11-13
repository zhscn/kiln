use kiln_cg::{lir::program, packet, sexp};
use std::{fs, path::PathBuf, process::Command};

fn source(body: &str) -> String {
    format!(
        r#"(lir-module "test" (init "body")
      (function "body" (receive 5)
        (vars (a obj) (b obj) (f obj) (x word) (y word) (m mv) (n mv) (d f64))
        {body}))"#
    )
}

fn compile(text: &str) -> Result<kiln_cg::kir::Module, String> {
    program::compile(&sexp::parse_one(text).unwrap())
}

fn reject(body: &str, message: &str) {
    let err = compile(&source(body)).unwrap_err();
    assert!(err.contains(message), "expected {message:?}, got {err:?}");
}

#[test]
fn independent_payload_is_typed_and_does_not_accept_kir_escape_hatches() {
    let text = source("(block entry (set a (fixnum 12)) (return (a)))");
    let ast = sexp::parse_one(&text).unwrap();
    let bytes = packet::encode(&ast, packet::schema::LIR_PAYLOAD).unwrap();
    let from_packet = packet::load(&bytes).unwrap();
    let from_owned_snapshot = packet::compile_program(&ast).unwrap();
    assert_eq!(
        format!("{from_packet:?}"),
        format!("{from_owned_snapshot:?}")
    );
    assert!(packet::load(&packet::encode(&ast, packet::schema::KIR_PAYLOAD).unwrap()).is_err());
    let kir = sexp::parse_one(r#"(module "raw" (init "entry"))"#).unwrap();
    assert!(packet::load(&packet::encode(&kir, packet::schema::LIR_PAYLOAD).unwrap()).is_err());
    for body in [
        "(block entry (set a (load x 0)) (return (a)))",
        "(block entry (set a (addr \"raw\" 5)) (return (a)))",
        "(block entry (set a (test general b)) (return (a)))",
        "(block entry (set a (field-ref function.entry b)) (return (a)))",
        "(block entry (call-lisp a x f (ctx self nargs a0) nil) (return (a)))",
        "(block entry (set a ctx) (return (a)))",
    ] {
        assert!(compile(&source(body)).is_err(), "accepted {body}");
    }
}

#[test]
fn representations_constants_and_declarations_are_checked_before_lowering() {
    reject(
        "(block entry (set x (fixnum 12)) (return (a)))",
        "expected Obj",
    );
    reject(
        "(block entry (set a (word 12)) (return (a)))",
        "expected Word",
    );
    reject(
        "(block entry (set a (fixnum 4611686018427387904)) (return (a)))",
        "fixnum constant",
    );
    reject(
        "(block entry (set a (character 1114112)) (return (a)))",
        "character constant",
    );
    reject(
        "(block entry (set a (arg-ref 5)) (return (a)))",
        "receive declaration",
    );
    reject(
        "(block entry (set a (literal 0)) (return (a)))",
        "literal index",
    );
    reject(
        "(block entry (set a (function \"missing\")) (return (a)))",
        "undefined function",
    );
    reject(
        "(block entry (set a (nil)) (set x (word 0)) (set b (select x a x)) (return (b)))",
        "expected Obj",
    );
    reject(
        "(block entry (set a missing) (return (a)))",
        "undeclared variable",
    );
    reject(
        "(block entry (set a (nil)) (branch a entry entry))",
        "expected Word",
    );
    reject("(block entry (set d (f64 0)) (return (d)))", "expected Obj");
    reject(
        "(block entry (set a (nil)) (alloc b double-float heap (a)) (return (b)))",
        "expected F64",
    );
    reject(
        "(block entry (set a (nil)) (alloc b cons heap (a)) (return (b)))",
        "field count",
    );
    for text in [
        r#"(lir-module "x" (init "missing"))"#,
        r#"(lir-module "x" (init "f") (init "f"))"#,
        r#"(lir-module "x" (init "f") (function "f") (function "f"))"#,
        r#"(lir-module "x" (init "f") (function "f" (vars (a obj) (a word))))"#,
        r#"(lir-module "x" (init "f") (function "f" (receive 1025) (block e (return ()))))"#,
        r#"(lir-module "x" (init "_kiln_lir_reserved") (function "_kiln_lir_reserved" (block e (return ()))))"#,
        r#"(lir-module "x" (init "f") (literals -1) (function "f" (block e (return ()))))"#,
    ] {
        assert!(compile(text).is_err(), "accepted {text}");
    }
}

#[test]
fn cfg_and_definite_initialization_use_all_predecessors_and_loop_entry() {
    reject("(block entry (return (a)))", "not initialized");
    reject("(block entry (set a a) (return (a)))", "not initialized");
    reject("(block entry (jump missing))", "undefined block");
    reject("(block entry (trap)) (block entry (trap))", "duplicate");
    let dead = compile(&source(
        "(block entry (return ())) (block dead (return (a)))",
    ))
    .unwrap();
    assert!(!format!("{dead:?}").contains("name: \"b1\""));
    reject("(block entry (return ()) (trap))", "after terminator");
    reject("(block entry (set a (nil)))", "unterminated");
    reject(
        "(block entry (set x (word 1)) (switch x entry (1 entry) (1 entry)))",
        "duplicate switch",
    );
    reject(
        r#"(block entry (set x (word 1)) (branch x yes no))
        (block yes (set a (nil)) (jump done))
        (block no (jump done)) (block done (return (a)))"#,
        "not initialized",
    );
    reject(
        r#"(block entry (jump loop))
        (block loop (set b a) (set a (nil)) (jump loop))"#,
        "not initialized",
    );
    compile(&source(
        r#"(block entry (set x (word 1)) (branch x yes no))
        (block yes (set a (nil)) (jump done))
        (block no (set a (t)) (jump done)) (block done (return (a)))"#,
    ))
    .unwrap();
    compile(&source(
        r#"(block entry (set a (nil)) (jump loop))
        (block loop (set b a) (set a b) (set x (word 0)) (branch x loop done))
        (block done (return (a)))"#,
    ))
    .unwrap();
}

#[test]
fn temporary_multiple_values_expire_at_overwrites_and_safepoints() {
    compile(&source(
        r#"(block entry (set a (nil)) (values m (a a))
        (set b (mv-ref m 1)) (set x (mv-count m)) (return-mv m))"#,
    ))
    .unwrap();
    reject(
        "(block entry (set a (mv-ref m 0)) (return (a)))",
        "not initialized",
    );
    reject(
        "(block entry (values m ()) (set n m) (return-mv n))",
        "cannot be copied",
    );
    reject(
        "(block entry (values m ()) (values n ()) (return-mv m))",
        "expired",
    );
    reject(
        "(block entry (values m ()) (poll) (return-mv m))",
        "expired",
    );
    reject(
        "(block entry (set a (nil)) (values m ()) (alloc b cons heap (a a)) (return-mv m))",
        "expired",
    );
    reject(
        "(block entry (values m ()) (set a (mv-ref m 1025)) (return (a)))",
        "index out of range",
    );
    reject(
        r#"(block entry (set f (function "body")) (values m ())
        (call n f ()) (return-mv m))"#,
        "expired",
    );
    reject(
        r#"(block entry (set x (word 0)) (values m ()) (branch x left right))
        (block left (values n ()) (jump done)) (block right (jump done))
        (block done (return-mv m))"#,
        "expired",
    );
    reject(
        r#"(block entry (values m ()) (jump loop))
        (block loop (set x (mv-count m)) (branch x loop done))
        (block done (return-mv m))"#,
        "expired",
    );
    // Both incoming paths establish the same named view. Its primary and count
    // become ordinary KIR phi values; the transfer area follows the chosen path.
    compile(&source(
        r#"(block entry (set x (word 0)) (branch x left right))
        (block left (values m ()) (jump done))
        (block right (set a (nil)) (values m (a)) (jump done))
        (block done (return-mv m))"#,
    ))
    .unwrap();
}

#[test]
fn saved_values_are_objects_and_restoration_establishes_a_new_view() {
    compile(&source("(block entry (set a (nil)) (values m (a a)) (mv-save b m) (poll) (mv-restore n b) (return-mv n))")).unwrap();
    reject(
        "(block entry (values m ()) (mv-save a m) (return-mv m))",
        "expired",
    );
    reject(
        "(block entry (mv-save a m) (return (a)))",
        "not initialized",
    );
    reject(
        "(block entry (mv-restore m a) (return-mv m))",
        "not initialized",
    );
    reject(
        "(block entry (values m ()) (mv-save x m) (return ()))",
        "expected Obj",
    );
    reject(
        "(block entry (set x (word 0)) (mv-restore m x) (return-mv m))",
        "expected Obj",
    );
}

#[test]
fn spread_calls_check_representations_views_and_exception_edges() {
    reject(
        "(block e (set f (function \"body\")) (set x (word 0)) (call-spread m f () x) (return-mv m))",
        "expected Obj",
    );
    reject(
        "(block e (set f (function \"body\")) (call-spread m f () a) (return-mv m))",
        "not initialized",
    );
    reject(
        "(block e (set a (nil)) (set f (function \"body\")) (values m ()) (call-spread n f () a) (return-mv m))",
        "expired",
    );
    let source = source(
        r#"(region r catch nil land)
      (block e (set a (nil)) (set f (function "body")) (enter r (a))
        (call-spread m f () a (region r) (loc 10 20)) (leave r) (return-mv m))
      (block land (landing r n) (return-mv m))"#,
    );
    let err = compile(&source).unwrap_err();
    assert!(err.contains("not initialized"), "{err}");
    let missing_region = source.replace(" (region r) (loc 10 20)", "");
    let err = compile(&missing_region).unwrap_err();
    assert!(err.contains("call region"), "{err}");
    let wrong_fixed = source.replace("m f () a", "m f (x) a");
    assert!(compile(&wrong_fixed).unwrap_err().contains("expected Obj"));
}

#[test]
fn closures_validate_capture_shapes_and_initialization_before_lowering() {
    reject(
        "(block e (set a (capture-ref 0)) (return (a)))",
        "capture index",
    );
    reject(
        "(block e (values m ()) (alloc-closure a \"body\" heap) (return-mv m))",
        "expired",
    );
    reject(
        "(block e (make-closure a \"body\" heap (b)) (return (a)))",
        "capture count",
    );
    reject(
        "(block e (capture-set a \"body\" 0 b) (return (a)))",
        "capture index",
    );
    let header = r#"(lir-module "closures" (init "main")
      (function "captured" (captures 1) (vars (a obj)) (block e (set a (capture-ref 0)) (return (a))))"#;
    let module = |body: &str| {
        format!(
            "{} (function \"main\" (vars (a obj) (b obj) (x word) (m mv)) {body}))",
            header
        )
    };
    for (body, error) in [
        (
            "(block e (set a (function \"captured\")) (return (a)))",
            "requires a closure",
        ),
        (
            "(block e (make-closure a \"captured\" heap (b)) (return (a)))",
            "not initialized",
        ),
        (
            "(block e (set x (word 0)) (make-closure a \"captured\" heap (x)) (return (a)))",
            "expected Obj",
        ),
        (
            "(block e (make-closure a \"missing\" heap ()) (return (a)))",
            "undefined function",
        ),
        (
            "(block e (alloc-closure a \"captured\" heap) (capture-set a \"captured\" 1 a) (return (a)))",
            "capture index",
        ),
    ] {
        let err = compile(&module(body)).unwrap_err();
        assert!(err.contains(error), "expected {error}, got {err}");
    }
    let parsed = compile(&module(
        "(block e (set a (nil)) (make-closure a \"captured\" heap (a)) (return (a)))",
    ))
    .unwrap();
    assert!(
        !parsed
            .data
            .iter()
            .any(|d| d.name == "_kiln_lir_object_captured")
    );
    for text in [
        "(lir-module \"x\" (init \"f\") (function \"f\" (captures 1) (block e (return ()))))",
        "(lir-module \"x\" (init \"f\") (function \"f\" (captures 0) (captures 0) (block e (return ()))))",
        "(lir-module \"x\" (init \"f\") (function \"f\" (captures 100000000) (block e (return ()))))",
    ] {
        assert!(compile(text).is_err(), "accepted {text}");
    }
}

#[test]
fn stack_storage_requires_matching_objects_and_active_root_regions() {
    let declarations = "(stack-object pair cons) (region roots stack-roots nil pair)";
    let program = |body: &str| source(&format!("{declarations} {body}"));
    for (body, message) in [
        (
            "(block e (set a (nil)) (alloc b cons (stack pair) (a a)) (return ()))",
            "no active root region",
        ),
        (
            "(block e (enter roots ()) (set a (nil)) (alloc b complex (stack pair) (a a)) (leave roots) (return ()))",
            "object kind",
        ),
        (
            "(block e (enter roots (a)) (leave roots) (return ()))",
            "argument count",
        ),
        ("(block e (enter roots ()) (return ()))", "active regions"),
        (
            "(block e (enter roots ()) (set f (function \"body\")) (call m f () (region roots)) (leave roots) (return-mv m))",
            "call region",
        ),
        (
            "(block e (enter roots ()) (alloc b cons (stack pair) (a a)) (leave roots) (return ()))",
            "not initialized",
        ),
    ] {
        let err = compile(&program(body)).unwrap_err();
        assert!(err.contains(message), "expected {message}, got {err}");
    }
    for invalid in [
        "(stack-object pair cons) (stack-object pair cons) (block e (return ()))",
        "(region roots stack-roots nil) (block e (return ()))",
        "(region roots stack-roots nil missing) (block e (return ()))",
        "(stack-object pair (closure \"missing\")) (block e (return ()))",
        "(stack-object pair cons) (region first stack-roots nil pair) (region second stack-roots first pair) (block e (enter first ()) (enter second ()) (trap))",
        "(block e (set a (nil)) (alloc b cons (stack missing) (a a)) (return ()))",
    ] {
        assert!(compile(&source(invalid)).is_err(), "accepted {invalid}");
    }
    // Root setup, stack allocation and teardown do not clobber a view.
    compile(&program("(block e (set a (nil)) (values m (a a)) (enter roots ()) (alloc b cons (stack pair) (a a)) (leave roots) (return-mv m))")).unwrap();
    let closure = r#"(lir-module "stack" (init "main")
      (function "entry" (captures 1) (vars (a obj)) (block e (set a (capture-ref 0)) (return (a))))"#;
    let module = |body: &str| {
        format!(
            "{closure} (function \"main\" (vars (a obj) (b obj) (m mv)) (stack-object fun (closure \"entry\")) (region roots stack-roots nil fun) {body}))"
        )
    };
    compile(&module("(block e (set a (nil)) (enter roots ()) (values m (a)) (make-closure b \"entry\" (stack fun) (a)) (leave roots) (return-mv m))")).unwrap();
    let err = compile(&module("(block e (enter roots ()) (alloc-closure a \"main\" (stack fun)) (leave roots) (return ()))")).unwrap_err();
    assert!(err.contains("declared entry"), "{err}");
    let err = compile(&module(
        "(block e (alloc-closure a \"entry\" (stack fun)) (return ()))",
    ))
    .unwrap_err();
    assert!(err.contains("no active root region"), "{err}");
}

#[test]
fn stack_declarations_bound_native_frame_sizes_and_initialization_expansion() {
    let captures = kiln_cg::packet::schema::MAX_BYTES / 16;
    let program = |declarations: &str, body: &str| {
        format!(
            r#"(lir-module "budget" (init "main")
      (function "wide" (captures {captures}) (block e (return ())))
      (function "main" (vars (f obj)) {declarations} {body}))"#
        )
    };
    let text = program(
        "(stack-object fun (closure \"wide\")) (region roots stack-roots nil fun)",
        "(block e (enter roots ()) (alloc-closure f \"wide\" (stack fun)) (leave roots) (return ()))",
    );
    assert!(compile(&text).unwrap_err().contains("expansion budget"));
    let objects = (0..17)
        .map(|i| format!("(stack-object f{i} (closure \"wide\"))"))
        .collect::<Vec<_>>()
        .join(" ");
    let text = program(&objects, "(block e (return ()))");
    assert!(compile(&text).unwrap_err().contains("target address range"));
}

#[test]
fn dynamic_regions_verify_stacks_landings_and_exceptional_initialization() {
    let declarations = r#"(region outer catch nil caught)
        (region inner unwind-protect outer cleanup)"#;
    let body = |text: &str| {
        source(&format!(
            "{declarations} {text}
        (block caught (landing outer n) (return-mv n))
        (block cleanup (landing inner) (continue-unwind inner))"
        ))
    };
    let reject_region = |text, message: &str| {
        let err = compile(&body(text)).unwrap_err();
        assert!(err.contains(message), "expected {message}, got {err}");
    };
    reject_region(
        "(block entry (set a (nil)) (enter inner ()))",
        "unterminated",
    );
    reject_region(
        "(block entry (enter outer (a)) (leave outer) (return ()))",
        "not initialized",
    );
    reject_region("(block entry (enter inner ()) (trap))", "wrong outer");
    reject_region(
        "(block entry (set a (nil)) (enter outer (a)) (enter outer (a)) (trap))",
        "already active",
    );
    reject_region("(block entry (leave outer) (return ()))", "not innermost");
    reject_region(
        "(block entry (set a (nil)) (enter outer (a)) (enter inner ()) (leave outer) (trap))",
        "not innermost",
    );
    reject_region(
        "(block entry (set a (nil)) (enter outer (a)) (return (a)))",
        "active regions",
    );
    reject_region(
        "(block entry (set f (function \"body\")) (set a (nil)) (enter outer (a)) (tail-call f ()))",
        "active regions",
    );
    reject_region("(block entry (jump caught))", "ordinary control flow");
    reject_region(
        "(block entry (set a (nil)) (enter outer (a)) (continue-unwind outer))",
        "requires unwind-protect",
    );
    reject_region(
        "(block entry (set a (nil)) (enter outer (a)) (enter inner ()) (continue-unwind inner))",
        "running cleanup",
    );
    reject_region(
        "(block entry (set a (nil)) (enter outer (a)) (set f (function \"body\")) (call m f ()) (trap))",
        "call region",
    );
    reject_region(
        "(block entry (set a (nil)) (enter outer (a)) (enter inner ()) (set f (function \"body\")) (call m f () (region outer)) (trap))",
        "call region",
    );
    let err = compile(&source(
        r#"(region r catch nil land)
        (block e (set a (nil)) (enter r (a)) (set f (function "body"))
          (call m f () (region r)) (leave r) (return ()))
        (block land (landing r n) (set b (mv-ref m 0)) (return (b)))"#,
    ))
    .unwrap_err();
    assert!(err.contains("not initialized"), "{err}");
    // The second call has defined B, but the first call can land before B exists.
    let err = compile(&source(
        r#"(region r catch nil land)
        (block e (set a (nil)) (enter r (a)) (set f (function "body"))
          (call m f () (region r)) (set b a) (call m f () (region r)) (leave r) (return ()))
        (block land (landing r n) (return (b)))"#,
    ))
    .unwrap_err();
    assert!(err.contains("not initialized"), "{err}");
    for invalid in [
        "(region r catch r land) (block e (return ())) (block land (landing r m) (return-mv m))",
        "(region r catch missing land) (block e (return ())) (block land (landing r m) (return-mv m))",
        "(region r catch nil land) (region s catch nil land) (block e (return ())) (block land (landing r m) (return-mv m))",
        "(region r catch nil land) (block e (return ())) (block land (landing r) (return ()))",
        "(region r unwind-protect nil land) (block e (return ())) (block land (landing r m) (trap))",
        "(region r catch nil land) (block e (return ())) (block land (return ()))",
        "(region r catch nil e) (block e (landing r m) (return-mv m))",
    ] {
        assert!(compile(&source(invalid)).is_err(), "accepted {invalid}");
    }
    compile(&body(
        "(block entry (set a (nil)) (enter outer (a)) (enter inner ()) (values m ()) (throw a m))",
    ))
    .unwrap();
    // A region with no possible unwind needs no generated landing code.
    let module = compile(&body(
        "(block entry (set a (nil)) (enter outer (a)) (leave outer) (return (a)))",
    ))
    .unwrap();
    assert!(!format!("{module:?}").contains("name: \"b1\""));
}

#[test]
fn binding_regions_share_outer_handlers_and_progv_expires_borrowed_values() {
    for invalid in [
        "(region b bind nil land) (block e (return ())) (block land (landing b m) (trap))",
        "(region b progv nil land) (block e (return ())) (block land (trap))",
        "(region b bind nil) (block e (set a (nil)) (enter b (a)) (trap))",
        "(region b progv nil) (block e (set a (nil)) (values m ()) (enter b (a a)) (leave b) (return-mv m))",
    ] {
        assert!(compile(&source(invalid)).is_err(), "accepted {invalid}");
    }
    compile(&source(
        r#"(region b bind nil)
        (block e (set a (nil)) (set f (function "body")) (enter b (a a))
          (call m f ()) (leave b) (return-mv m))"#,
    ))
    .unwrap();
    let err = compile(&source(
        r#"(region b bind nil)
        (block e (set a (nil)) (set f (function "body")) (enter b (a a))
          (call m f () (region b)) (leave b) (return-mv m))"#,
    ))
    .unwrap_err();
    assert!(err.contains("call region"), "{err}");
    // Before the progv entry is linked, saving bindings can allocate and
    // unwind. Its exceptional path cannot read B, assigned only afterwards.
    let err = compile(&source(
        r#"(region r catch nil land) (region b progv r)
        (block e (set a (nil)) (enter r (a)) (enter b (a a)) (set b a)
          (leave b) (leave r) (return ()))
        (block land (landing r m) (return (b)))"#,
    ))
    .unwrap_err();
    assert!(err.contains("not initialized"), "{err}");
    // Two paths cannot disagree about which runtime entries are linked.
    let err = compile(&source(
        r#"(region b bind nil)
        (block e (set a (nil)) (set x (word 0)) (branch x yes no))
        (block yes (enter b (a a)) (jump done)) (block no (jump done))
        (block done (trap))"#,
    ))
    .unwrap_err();
    assert!(err.contains("inconsistent region stack"), "{err}");
}

#[test]
fn lowering_owns_argument_snapshots_calling_convention_and_cycle_polls() {
    let module = compile(&source(
        r#"(block entry (set a (arg-ref 4))
        (set f (function "body")) (call m f (a a a a a) (loc 12 24))
        (set b (arg-ref 4)) (return (b)))"#,
    ))
    .unwrap();
    let f = &module.funcs[0];
    let entry = format!("{:?}", f.blocks[0]);
    let offset = core::mem::offset_of!(kiln_rt::context::Context, values) + 8;
    assert!(entry.contains(&format!("Load(Var(\"ctx\"), {offset})")));
    let call = f
        .blocks
        .iter()
        .flat_map(|b| &b.stmts)
        .find(|s| {
            matches!(
                s,
                kiln_cg::kir::Stmt::CallLisp {
                    loc: Some((12, 24)),
                    ..
                }
            )
        })
        .unwrap();
    assert!(matches!(call, kiln_cg::kir::Stmt::CallLisp { args, .. } if args.len() == 6));
    let looped = compile(&source(
        r#"(block entry (set x (word 0)) (branch x a b))
        (block a (branch x b done)) (block b (branch x a done))
        (block done (return ()))"#,
    ))
    .unwrap();
    let poll_calls = looped.funcs[0]
        .blocks
        .iter()
        .flat_map(|b| &b.stmts)
        .filter(|s| {
            matches!(s,
        kiln_cg::kir::Stmt::CallRt { name, .. } if name == "kiln_rt_poll")
        })
        .count();
    assert_eq!(poll_calls, 2, "entry plus an irreducible-loop poll");
    let first = format!("{looped:?}");
    let second = format!(
        "{:?}",
        compile(&source(
            r#"(block entry (set x (word 0)) (branch x a b))
        (block a (branch x b done)) (block b (branch x a done))
        (block done (return ()))"#
        ))
        .unwrap()
    );
    assert_eq!(first, second, "lowering order must be deterministic");
}

struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        static SERIAL: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let serial = SERIAL.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("kiln-lir-{}-{serial}", std::process::id()));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn write(&self, name: &str, data: impl AsRef<[u8]>) -> PathBuf {
        let path = self.0.join(name);
        fs::write(&path, data).unwrap();
        path
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn independent_lir_executes_calls_multivalues_loops_and_argument_snapshots() {
    let text = r#"(lir-module "execution" (init "start")
      (function "start" (block e (return ())))
      (function "exercise-gc" (vars (a obj) (b obj) (x word) (y word) (condition word))
        (block e (set a (fixnum 42)) (set b (nil)) (alloc a cons heap (a b))
          (set x (word 150000)) (set y (word 1)) (jump loop))
        (block loop (alloc b cons heap (a a)) (set x (word-sub x y))
          (set condition (word-lt y x)) (branch condition loop done))
        (block done (set a (field-ref cons.car b)) (set a (field-ref cons.car a)) (return (a))))
      (function "floating" (vars (d f64) (e f64) (a obj))
        (block e (set d (f64 4609434218613702656)) (set e (f64 4611686018427387904))
          (set d (f64-add d e)) (alloc a double-float heap (d))
          (set d (unbox-double a)) (alloc a double-float heap (d)) (return (a))))
      (function "clobber" (vars (x obj))
        (block e (set x (fixnum 99)) (return (x x x x x))))
      (function "callee" (receive 5) (vars (f obj) (a obj) (b obj) (m mv))
        (block e (set f (function "clobber")) (call m f ())
          (set a (arg-ref 3)) (set b (arg-ref 4)) (return (a b))))
      (function "calculate" (vars (f obj) (a obj) (b obj) (x word) (y word) (condition word) (m mv))
        (block e (set f (function "callee")) (set a (fixnum 40)) (set b (fixnum 2))
          (call m f (b b b a b)) (set a (mv-ref m 0)) (set b (mv-ref m 1))
          (set a (fixnum-add a b)) (set x (word 0)) (set y (word 3)) (jump loop))
        (block loop (set condition (word-lt x y)) (branch condition body done))
        (block body (set x (word 1)) (set y (word-sub y x)) (set x (word 0)) (jump loop))
        (block done (set condition (test symbol a)) (set b (fixnum-tag condition)) (return (a b)))))"#;
    let temp = Temp::new();
    let lir = temp.write(
        "program.lir",
        packet::encode(&sexp::parse_one(text).unwrap(), packet::schema::LIR_PAYLOAD).unwrap(),
    );
    // The KIR harness observes the LIR result through the ordinary runtime ABI.
    // A stack-overflow stub keeps this fixture independent of a bootstrapped kernel.
    let harness = temp.write(
        "harness.kir",
        r#"(module "probe" (init "probe-object")
      (import-func "kiln_rt_print" 2 1)
      (data "probe-object" (static-function "probe"))
      (data "overflow-object" (static-function "overflow"))
      (data "kiln_sym_KILN_2E_KERNEL_3A__25_STACK_2D_EXHAUSTED"
        (static-symbol 0 0 (object-data "overflow-object" general) 0 0 0))
      (func "overflow" (block e (trap)))
      (func "probe" (vars (f obj) (v obj) (n raw) (w obj) (ignored raw))
        (block e (set f (object-address "_kiln_lir_object_exercise-gc" general))
          (invoke v n f () nil) (call-rt "kiln_rt_print" (ignored) (ctx v) nil)
          (set f (object-address "_kiln_lir_object_floating" general))
          (invoke v n f () nil) (call-rt "kiln_rt_print" (ignored) (ctx v) nil)
          (set f (object-address "_kiln_lir_object_calculate" general))
          (invoke v n f () nil) (set w (secondary-value-ref 1))
          (call-rt "kiln_rt_print" (ignored) (ctx v) nil)
          (call-rt "kiln_rt_print" (ignored) (ctx w) nil) (return v 1))))"#,
    );
    for stress in [false, true] {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_kiln-cg"));
        cmd.arg("jit")
            .arg(&lir)
            .arg(&harness)
            .env("KILN_VERIFY", "1");
        if stress {
            cmd.env("MMTK_GC_TRIGGER", "FixedHeapSize:1048576");
            cmd.env("KILN_GC_STATS", temp.0.join("gc.tsv"));
        }
        let output = cmd.output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "42\n3.5d0\n42\n0\n"
        );
        if stress {
            assert!(
                fs::read_to_string(temp.0.join("gc.tsv"))
                    .unwrap()
                    .lines()
                    .count()
                    > 1,
                "the root test must cross an actual collection"
            );
        }
    }
    let output = Command::new(env!("CARGO_BIN_EXE_kiln-cg"))
        .arg("obj")
        .arg(&lir)
        .arg(&harness)
        .arg("-o")
        .arg(temp.0.join("program.o"))
        .env("KILN_VERIFY", "1")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(fs::metadata(temp.0.join("program.o")).unwrap().len() > 0);
}

#[test]
fn independent_regions_unwind_across_calls_and_keep_pending_values_rooted() {
    let text = include_str!("fixtures/lir-unwind.lisp-expr");
    // Build a verified module before invoking a subprocess, so verifier
    // failures remain ordinary diagnostics rather than an exit-status mismatch.
    let module = compile(text).unwrap();
    assert!(module.funcs.iter().any(|f| {
        f.slots
            .iter()
            .any(|(_, size)| *size == size_of::<kiln_rt::context::DynEntry>() as u32)
    }));
    let temp = Temp::new();
    let lir = temp.write(
        "program.lir",
        packet::encode(&sexp::parse_one(text).unwrap(), packet::schema::LIR_PAYLOAD).unwrap(),
    );
    let vars = (0..14)
        .map(|i| format!("(w{i} obj)"))
        .collect::<Vec<_>>()
        .join(" ");
    let read = (1..14)
        .map(|i| format!("(set w{i} (secondary-value-ref {i}))"))
        .collect::<Vec<_>>()
        .join(" ");
    let print = (0..14)
        .map(|i| format!("(call-rt \"kiln_rt_print\" (ignored) (ctx w{i}) nil)"))
        .collect::<Vec<_>>()
        .join(" ");
    // Keep the entry stack limit unchanged while requesting a loop poll, so
    // the landing's generated slow path must preserve the unwind payload.
    let poll_offset = core::mem::offset_of!(kiln_rt::context::Context, poll_flag);
    let harness = temp.write(
        "harness.kir",
        format!(
            r#"(module "probe" (init "probe-object")
      (import-func "kiln_rt_print" 2 1)
      (data "probe-object" (static-function "probe"))
      (data "failure-object" (static-function "failure"))
      (data "special-one" (static-symbol 0 0 0 (fixnum 31) 0 0))
      (data "special-two" (static-symbol 0 0 0 (fixnum 32) 0 0))
      (symbol-roots "special-one" 106 107)
      (symbol-roots "special-two" 106 107)
      (data "kiln_sym_KILN_2E_KERNEL_3A__25_STACK_2D_EXHAUSTED"
        (static-symbol 0 0 (object-data "failure-object" general) 0 0 0))
      (data "kiln_sym_KILN_2E_KERNEL_3A__25_RUNTIME_2D_ERROR"
        (static-symbol 0 0 (object-data "failure-object" general) 0 0 0))
      (func "failure" (block e (trap)))
      (func "kiln_undefined_function" (block e (trap)))
      (func "kiln_undefined_setf_function" (block e (trap)))
      (func "probe" (vars (f obj) (v obj) (n raw) (s obj) (t obj) (ignored raw) {vars})
        (block e (store ctx {poll_offset} 1)
          (set f (object-address "_kiln_lir_object_exit-reenter" general))
          (invoke v n f () nil) (set w0 v)
          (set w1 (secondary-value-ref 1)) (set w2 (secondary-value-ref 2))
          (call-rt "kiln_rt_print" (ignored) (ctx w0) nil)
          (call-rt "kiln_rt_print" (ignored) (ctx w1) nil)
          (call-rt "kiln_rt_print" (ignored) (ctx w2) nil)
          (call-rt "kiln_rt_print" (ignored) (ctx (fixnum-tag (load ctx {poll_offset}))) nil)
          (set f (object-address "_kiln_lir_object_run" general))
          (set s (object-address "special-one" general)) (set t (object-address "special-two" general))
          (invoke v n f (s t) nil) (set w0 v) {read}
          (call-rt "kiln_rt_print" (ignored) (ctx (fixnum-tag n)) nil)
          {print} (return v 1))))"#
        ),
    );
    for stress in [false, true] {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_kiln-cg"));
        cmd.arg("jit")
            .arg(&lir)
            .arg(&harness)
            .env("KILN_VERIFY", "1");
        if stress {
            cmd.env("MMTK_GC_TRIGGER", "FixedHeapSize:1048576")
                .env("KILN_GC_STATS", temp.0.join("gc.tsv"));
        }
        let output = cmd.output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "55\n56\n3\n0\n14\n(7 (7))\n(7 (7))\n(7 (7) 77)\n(99)\n(55 56)\nNIL\n(NIL)\n(7 (7))\n(1 31 31)\n(9 31)\n(2 1 31 32)\n(2 31 32)\n(88)\n(55 56 3)\n"
        );
        if stress {
            assert!(
                fs::read_to_string(temp.0.join("gc.tsv"))
                    .unwrap()
                    .lines()
                    .count()
                    > 1
            );
        }
    }
    let output = Command::new(env!("CARGO_BIN_EXE_kiln-cg"))
        .arg("obj")
        .arg(&lir)
        .arg(&harness)
        .arg("-o")
        .arg(temp.0.join("program.o"))
        .env("KILN_VERIFY", "1")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn check_object_results(text: &str, count: usize, expected: &str) {
    compile(text).unwrap();
    let temp = Temp::new();
    let lir = temp.write(
        "program.lir",
        packet::encode(&sexp::parse_one(text).unwrap(), packet::schema::LIR_PAYLOAD).unwrap(),
    );
    let vars = (0..count)
        .map(|i| format!("(w{i} obj)"))
        .collect::<Vec<_>>()
        .join(" ");
    let read = (1..count)
        .map(|i| format!("(set w{i} (secondary-value-ref {i}))"))
        .collect::<Vec<_>>()
        .join(" ");
    let print = (0..count)
        .map(|i| format!("(call-rt \"kiln_rt_print\" (ignored) (ctx w{i}) nil)"))
        .collect::<Vec<_>>()
        .join(" ");
    let harness = temp.write("harness.kir", format!(r#"(module "probe" (init "probe-object")
      (import-func "kiln_rt_print" 2 1)
      (data "probe-object" (static-function "probe")) (data "failure-object" (static-function "failure"))
      (data "kiln_sym_KILN_2E_KERNEL_3A__25_STACK_2D_EXHAUSTED" (static-symbol 0 0 (object-data "failure-object" general) 0 0 0))
      (data "kiln_sym_KILN_2E_KERNEL_3A__25_RUNTIME_2D_ERROR" (static-symbol 0 0 (object-data "failure-object" general) 0 0 0))
      (func "failure" (block e (trap)))
      (builtin undefined-function file) (builtin undefined-setf-function file)
      (builtin funcallable-trampoline file) (builtin funcallable-unset file)
      (func "probe" (vars (f obj) (v obj) (n raw) (ignored raw) {vars})
        (block e (set f (object-address "_kiln_lir_object_run" general))
          (invoke v n f () nil) (set w0 v) {read}
          (call-rt "kiln_rt_print" (ignored) (ctx (fixnum-tag n)) nil) {print} (return v 1))))"#));
    for stress in [false, true] {
        let mut command = Command::new(env!("CARGO_BIN_EXE_kiln-cg"));
        command
            .arg("jit")
            .arg(&lir)
            .arg(&harness)
            .env("KILN_VERIFY", "1");
        if stress {
            command
                .env("MMTK_GC_TRIGGER", "FixedHeapSize:1048576")
                .env("KILN_GC_STATS", temp.0.join("gc.tsv"));
        }
        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(String::from_utf8_lossy(&output.stdout), expected);
        if stress {
            assert!(
                fs::read_to_string(temp.0.join("gc.tsv"))
                    .unwrap()
                    .lines()
                    .count()
                    > 1
            );
        }
    }
    let output = Command::new(env!("CARGO_BIN_EXE_kiln-cg"))
        .arg("obj")
        .arg(&lir)
        .arg(&harness)
        .arg("-o")
        .arg(temp.0.join("program.o"))
        .env("KILN_VERIFY", "1")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn heap_closures_preserve_recursive_groups_captures_and_exit_tokens() {
    check_object_results(
        include_str!("fixtures/lir-closures.lisp-expr"),
        5,
        "5\n(42)\n(42)\n(0 42)\n(88 89)\n(42 42)\n",
    );
}

#[test]
fn stack_objects_root_fields_across_gc_calls_reentry_and_unwind() {
    check_object_results(
        include_str!("fixtures/lir-stack.lisp-expr"),
        5,
        "5\n(42 43)\n(42 43)\n(42)\n(42 7)\n(42)\n",
    );
}

#[test]
fn spread_calls_execute_empty_prefix_register_boundary_and_full_capacity() {
    let text = include_str!("fixtures/lir-spread.lisp-expr");
    compile(text).unwrap();
    let temp = Temp::new();
    let lir = temp.write(
        "program.lir",
        packet::encode(&sexp::parse_one(text).unwrap(), packet::schema::LIR_PAYLOAD).unwrap(),
    );
    let harness = temp.write("harness.kir", r#"(module "probe" (init "probe-object")
      (import-func "kiln_rt_print" 2 1)
      (data "probe-object" (static-function "probe")) (data "failure-object" (static-function "failure"))
      (data "kiln_sym_KILN_2E_KERNEL_3A__25_STACK_2D_EXHAUSTED" (static-symbol 0 0 (object-data "failure-object" general) 0 0 0))
      (data "kiln_sym_KILN_2E_KERNEL_3A__25_RUNTIME_2D_ERROR" (static-symbol 0 0 (object-data "failure-object" general) 0 0 0))
      (func "failure" (block e (trap))) (func "kiln_undefined_function" (block e (trap)))
      (func "kiln_undefined_setf_function" (block e (trap)))
      (func "probe" (vars (f obj) (v obj) (n raw) (first obj) (second obj) (third obj) (ignored raw))
        (block e (set f (object-address "_kiln_lir_object_run" general))
          (invoke v n f () nil) (set first v) (set second (secondary-value-ref 1)) (set third (secondary-value-ref 2))
          (call-rt "kiln_rt_print" (ignored) (ctx (fixnum-tag n)) nil)
          (call-rt "kiln_rt_print" (ignored) (ctx first) nil)
          (call-rt "kiln_rt_print" (ignored) (ctx second) nil)
          (call-rt "kiln_rt_print" (ignored) (ctx third) nil) (return v 1))))"#);
    let output = Command::new(env!("CARGO_BIN_EXE_kiln-cg"))
        .arg("jit")
        .arg(&lir)
        .arg(&harness)
        .env("KILN_VERIFY", "1")
        .env("MMTK_GC_TRIGGER", "FixedHeapSize:1048576")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "3\n(0)\n(10 40 4)\n(10 30 1024)\n"
    );
    let output = Command::new(env!("CARGO_BIN_EXE_kiln-cg"))
        .arg("obj")
        .arg(&lir)
        .arg(&harness)
        .arg("-o")
        .arg(temp.0.join("program.o"))
        .env("KILN_VERIFY", "1")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn constant_graph_validates_edges_and_preserves_cycles() {
    let text = r#"(lir-module "constants" (init "run")
      (constants (cons (fixnum 42) (constant 0)) (string "λ kiln")
                 (vector (constant 0) (constant 1)) (double-bits -9223372036854775808)
                 (bignum "18446744073709551616") (bignum "-18446744073709551617")
                 (ratio (fixnum -3) (fixnum 7))
                 (complex (constant 6) (fixnum 2)))
      (function "run" (vars (a obj) (b obj) (c obj) (n word) (one word) (more word) (p obj) (q obj) (r obj) (s obj))
        (block entry (set a (constant 0)) (set c (fixnum 42))
          (field-set cons.car a c) (set b (field-ref cons.cdr a))
          (set c (field-ref cons.car b)) (alloc c cons heap (c c))
          (field-set cons.car a c) (set c (nil)) (set a (constant 1))
          (set n (word 150000)) (set one (word 1)) (jump loop))
        (block loop (alloc b cons heap (a a)) (set n (word-sub n one))
          (set more (word-lt one n)) (branch more loop done))
        (block done (set b (constant 0)) (set b (field-ref cons.cdr b))
          (set c (field-ref cons.car b)) (set b (constant 2)) (set b (constant 3)) (set p (constant 4)) (set q (constant 5)) (set r (constant 6)) (set s (constant 7))
          (return (c a b p q r s)))))"#;
    assert!(
        compile(&text.replace("18446744073709551616", "42"))
            .unwrap_err()
            .contains("fits fixnum")
    );
    assert!(
        compile(&text.replace("(fixnum -3) (fixnum 7)", "(fixnum 3) (fixnum 6)"))
            .unwrap_err()
            .contains("normalized")
    );
    assert!(
        compile(&text.replace("(constant 6) (fixnum 2)", "(constant 6) (nil)"))
            .unwrap_err()
            .contains("imaginary")
    );
    // This checks self-relocation while printing only finite leaves.
    check_object_results(
        text,
        7,
        "7\n(42 . 42)\n\"λ kiln\"\n-0.0d0\n18446744073709551616\n-18446744073709551617\n-3/7\n#C(-3/7 2)\n",
    );
    assert!(
        compile(&text.replace("(constant 0)) (string", "(constant 9)) (string"))
            .unwrap_err()
            .contains("reference out of range")
    );
    assert!(compile(&text.replace("(string \"λ kiln\")", "(string 1114112)")).is_err());
    assert!(compile(&text.replace("(fixnum 42)", "(word 42)")).is_err());
    assert!(
        compile(&text.replace("(set a (constant 1))", "(set a (constant 99))"))
            .unwrap_err()
            .contains("constant index")
    );
}

#[test]
fn constant_literal_bindings_are_rooted_and_require_an_image() {
    let text = r#"(lir-module "bindings" (init "run") (literals 1)
      (constants (cons (literal 0) (constant 0)))
      (function "run" (vars (a obj))
        (block e (set a (constant 0)) (return (a)))))"#;
    let module = compile(text).unwrap();
    assert_eq!(module.literal_patches.len(), 1);
    let (name, word, literal) = &module.literal_patches[0];
    assert_eq!((*word, *literal), (1, 0));
    assert!(module.roots.contains(&(name.clone(), *word)));
    assert!(
        compile(&text.replace("(literal 0)", "(literal 1)"))
            .unwrap_err()
            .contains("literal reference")
    );
    let temp = Temp::new();
    let path = temp.write("bindings.lir", text);
    let output = Command::new(env!("CARGO_BIN_EXE_kiln-cg"))
        .arg("jit")
        .arg(path)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("image literal bindings"));
}

#[test]
fn constant_symbols_share_link_names_and_preserve_uninterned_identity() {
    let text = r#"(lir-module "symbols" (init "run")
      (constants (symbol "KEYWORD" "ANSWER") (symbol "TEST" "X")
        (uninterned "G" 7) (uninterned "G" 7) (uninterned "G" 8)
        (function "run") (symbol "COMMON-LISP" "NIL"))
      (function "run" (vars (a obj) (b obj) (c obj) (d obj) (e obj)
                           (x word) (one word) (more word))
        (block entry (set a (constant 0)) (set b (constant 1))
          (set c (constant 2)) (set d (constant 3)) (set x (eq c d))
          (set c (fixnum-tag x)) (set d (constant 2)) (set e (constant 4))
          (set x (eq d e)) (set d (fixnum-tag x)) (set e (constant 6))
          (set x (word 150000)) (set one (word 1)) (jump loop))
        (block loop (alloc e cons heap (a b)) (set x (word-sub x one))
          (set more (word-lt one x)) (branch more loop done))
        (block done (return (a b c d)))))"#;
    check_object_results(text, 4, "4\n:ANSWER\nX\n1\n0\n");
    let first = compile(text).unwrap();
    let second = compile(
        &text
            .replace("\"symbols\"", "\"other\"")
            .replace("\"run\"", "\"other-run\""),
    )
    .unwrap();
    let merged = kiln_cg::kir::merge(vec![first, second]).unwrap();
    assert_eq!(
        merged
            .data
            .iter()
            .filter(|d| d.name == "kiln_sym_TEST_3A_X")
            .count(),
        1
    );
    assert!(
        compile(&text.replace(
            "(uninterned \"G\" 7) (uninterned \"G\" 7)",
            "(uninterned \"G\" 7) (uninterned \"OTHER\" 7)"
        ))
        .unwrap_err()
        .contains("conflicting uninterned")
    );
    assert!(
        compile(&text.replace("(function \"run\")", "(function \"missing\")"))
            .unwrap_err()
            .contains("zero-capture")
    );
}

#[test]
fn constant_pool_folds_strings_and_acyclic_conses_but_preserves_cycles_and_vectors() {
    let text = r#"(lir-module "pool" (init "run")
      (constants (cons (constant 2) (nil)) (cons (constant 3) (nil))
        (string "same") (string 115 97 109 101)
        (cons (constant 0) (constant 1)) (cons (constant 1) (constant 0))
        (cons (fixnum 1) (constant 6)) (cons (fixnum 1) (constant 7))
        (vector (constant 0)) (vector (constant 0)))
      (function "run" (vars (a obj))
        (block entry (set a (constant 5)) (return (a)))))"#;
    let module = compile(text).unwrap();
    let constants: Vec<_> = module
        .data
        .iter()
        .filter(|d| d.name.starts_with("_kiln_lir_constant_"))
        .collect();
    assert_eq!(constants.len(), 7);
    for suffix in ["_1", "_3", "_5"] {
        assert!(!constants.iter().any(|d| d.name.ends_with(suffix)));
    }
    for suffix in ["_6", "_7", "_8", "_9"] {
        assert!(constants.iter().any(|d| d.name.ends_with(suffix)));
    }
}

#[test]
fn mutable_cells_keep_heap_values_alive_and_validate_indices() {
    let text = r#"(lir-module "cells" (init "run") (cells (nil) (fixnum 7))
      (function "run" (vars (a obj) (b obj) (n word) (one word) (more word))
        (block entry (set a (cell-ref 1)) (alloc b cons heap (a a))
          (cell-set 0 b) (set b (nil)) (set n (word 150000)) (set one (word 1)) (jump loop))
        (block loop (alloc b cons heap (a a)) (set n (word-sub n one))
          (set more (word-lt one n)) (branch more loop done))
        (block done (set a (cell-ref 0)) (return (a)))))"#;
    check_object_results(text, 1, "1\n(7 . 7)\n");
    assert!(
        compile(&text.replace("(cell-ref 1)", "(cell-ref 2)"))
            .unwrap_err()
            .contains("cell index")
    );
    assert!(
        compile(&text.replace("(cell-set 0 b)", "(cell-set 2 b)"))
            .unwrap_err()
            .contains("cell index")
    );
    assert!(
        compile(&text.replace("(cell-set 0 b)", "(cell-set 0 n)"))
            .unwrap_err()
            .contains("expected Obj")
    );
    assert!(
        compile(&text.replace("(cell-ref 1)", "b"))
            .unwrap_err()
            .contains("not initialized")
    );
}

#[test]
fn debug_metadata_is_semantic_rooted_and_checked_before_lowering() {
    let text = r#"(lir-module "debug" (init "run") (literals 3)
      (constants (string "file.lisp"))
      (function "run" (vars (a obj) (d f64) (m mv) (n word))
        (debug (literal 0) (constant 0) 10 20 ((a (literal 1) cell) (d (literal 2))))
        (block entry (set a (nil)) (return (a)))))"#;
    let module = compile(text).unwrap();
    let function = module.funcs.iter().find(|f| f.name == "run").unwrap();
    assert_eq!(function.labels, vec![("v0".into(), 0), ("v1".into(), 1)]);
    assert!(
        matches!(&function.debug,Some(kiln_cg::kir::DebugRef::Direct(kiln_cg::kir::Word::DataAddr(name,_))) if name == "_kiln_lir_debug_run")
    );
    for (name, word, _) in &module.literal_patches {
        assert!(module.roots.contains(&(name.clone(), *word)));
    }
    assert!(
        module
            .import_data
            .iter()
            .any(|n| n == "kiln_sym_KEYWORD_3A_CELL")
    );
    assert!(
        module
            .import_data
            .iter()
            .any(|n| n == "kiln_sym_KEYWORD_3A_DOUBLE_2D_BITS")
    );
    for (from, to, error) in [
        ("10 20", "21 20", "reversed debug"),
        (
            "(a (literal 1) cell)",
            "(missing (literal 1))",
            "not declared",
        ),
        ("(a (literal 1) cell)", "(m (literal 1))", "representation"),
        ("(a (literal 1) cell)", "(n (literal 1))", "representation"),
        ("(d (literal 2))", "(d (literal 2) cell)", "representation"),
        ("(d (literal 2))", "(a (literal 2))", "duplicate debug"),
        ("(literal 2)", "(literal 3)", "literal reference"),
    ] {
        assert!(
            compile(&text.replace(from, to))
                .unwrap_err()
                .contains(error),
            "{from} -> {to}"
        );
    }
}

#[test]
fn numeric_operations_own_runtime_dispatch_and_multiple_value_counts() {
    let text = include_str!("fixtures/lir-numeric.lisp-expr");
    check_object_results(text, 5, "5\n55340232221128654848\n-4\n3\n7.5d0\n5/2\n");
    assert!(
        compile(&text.replace("integer-mul (a b)", "integer-mul (a)"))
            .unwrap_err()
            .contains("arity")
    );
    assert!(
        compile(&text.replace("integer-mul (a b)", "integer-mul (a n)"))
            .unwrap_err()
            .contains("expected Obj")
    );
    assert!(
        compile(&text.replace("integer-mul (a b)", "raw-entry (a b)"))
            .unwrap_err()
            .contains("unknown numeric")
    );
    assert!(
        compile(&text.replace(
            "(numeric m number-add (a b))",
            "(numeric m number-add (a b)) (set a (mv-ref old 0))"
        ))
        .is_err()
    );
    reject(
        "(block entry (set a (fixnum 1)) (values n (a)) (numeric m number-add (a a)) (return-mv n))",
        "expired",
    );
    reject(
        "(block entry (numeric m number-add (a b)) (return-mv m))",
        "not initialized",
    );
}

#[test]
fn compatibility_numeric_operations_share_independent_lowering() {
    let module = kiln_cg::kir::parse_module(
        &sexp::parse_one(
            r#"(module "numeric" (init "f")
      (data "f" (static-function "run"))
      (func "run" (vars (v obj) (n raw))
        (block e (numeric-op v n integer-floor ((fixnum-tag 17) (fixnum-tag 5)) nil (loc 10 20))
          (return v n))))"#,
        )
        .unwrap(),
    )
    .unwrap();
    let import = module
        .import_funcs
        .iter()
        .find(|f| f.name == "kiln_rt_integer_op")
        .unwrap();
    assert!(import.unwinds && import.params == 4 && import.returns == 1);
    assert!(
        matches!(&module.funcs[0].blocks[0].stmts[0],kiln_cg::kir::Stmt::CallRt {name,loc:Some((10,20)),..} if name == "kiln_rt_integer_op")
    );
    assert!(matches!(
        &module.funcs[0].blocks[0].stmts[1],
        kiln_cg::kir::Stmt::Set(_, kiln_cg::kir::Expr::Int(2))
    ));
}

#[test]
fn errors_are_checked_terminators_with_exceptional_control_flow() {
    let module = compile(&source(
        "(block entry (set a (fixnum 42)) (error 4 a (loc 11 22)))",
    ))
    .unwrap();
    assert!(
        module
            .import_data
            .iter()
            .any(|n| n == kiln_rt::RUNTIME_ERROR_SYMBOL)
    );
    assert!(module.funcs[0].blocks.iter().flat_map(|b| &b.stmts).any(|s| matches!(s,kiln_cg::kir::Stmt::CallRt {name,loc:Some((11,22)),..} if name == "kiln_rt_error")));
    reject("(block entry (set a (nil)) (error 25 a))", "unknown error");
    reject(
        "(block entry (set a (nil)) (error 4 a (loc -1 10)))",
        "invalid location",
    );
    reject(
        "(block entry (set a (nil)) (error 4 a (loc 20 10)))",
        "reversed error",
    );
    reject("(block entry (error 4 a))", "not initialized");
    reject("(block entry (set x (word 1)) (error 4 x))", "expected Obj");
    reject(
        r#"(region r catch nil land)
        (block entry (set a (nil)) (enter r (a)) (error 4 a))
        (block land (landing r m) (return (b)))"#,
        "not initialized",
    );
    assert!(
        compile(&source(
            r#"(region r catch nil land)
        (block entry (set a (nil)) (enter r (a)) (error 4 a))
        (block land (landing r m) (return (a)))"#
        ))
        .is_ok()
    );
    for name in [
        "kiln_rt_number_op",
        "kiln_sym_TEST_3A_X",
        "_kiln_lir_debug_x",
    ] {
        let text = source("(block entry (return ()))").replace("\"body\"", &format!("\"{name}\""));
        assert!(compile(&text).unwrap_err().contains("reserved function"));
    }
}

#[test]
fn entry_rest_lists_are_rooted_before_poll_and_cleaned_on_return_tail_call_and_unwind() {
    let text = include_str!("fixtures/lir-arguments.lisp-expr");
    check_object_results(
        text,
        7,
        "7\n(30 40 50)\nNIL\n(42)\n(42)\n(42)\n(42)\n1024\n",
    );
    for (from, to, error) in [
        ("(rest tail 2)", "(rest missing 2)", "undeclared variable"),
        ("(rest tail 2)", "(rest tail 1025)", "rest start"),
        (
            "(rest tail 2)",
            "(rest tail 2) (rest tail 2)",
            "duplicate rest",
        ),
        (
            "(rest tail 1 (stack 3))",
            "(rest tail 1 (stack 1025))",
            "rest start",
        ),
    ] {
        assert!(
            compile(&text.replace(from, to))
                .unwrap_err()
                .contains(error)
        );
    }
}

#[test]
fn sequence_allocations_snapshot_aliases_initialize_unicode_and_keep_fields_rooted() {
    let text = include_str!("fixtures/lir-sequences.lisp-expr");
    check_object_results(text, 6, "6\n(43)\n\"λ!λλ𐀀\"\n#()\n\"\"\n#\\!\n1\n");
    assert!(
        compile(&text.replace("simple-vector length a", "simple-vector a a"))
            .unwrap_err()
            .contains("expected Word")
    );
    assert!(
        compile(&text.replace("simple-vector length a", "simple-vector length index"))
            .unwrap_err()
            .contains("expected Obj")
    );
    assert!(
        compile(&text.replace("(vector-set v index b)", "(vector-set v a b)"))
            .unwrap_err()
            .contains("expected Word")
    );
    assert!(
        compile(&text.replace("(string-set s index b)", "(string-set s index index)"))
            .unwrap_err()
            .contains("expected Obj")
    );
    assert!(
        compile(&text.replace("(vector v (v v))", "(vector v (v missing))"))
            .unwrap_err()
            .contains("undeclared variable")
    );
    reject(
        "(block entry (set x (word 2)) (alloc-sequence a simple-vector x b) (return (a)))",
        "not initialized",
    );
    reject(
        "(block entry (set a (nil)) (values m (a)) (set x (word 0)) (alloc-sequence b simple-vector x a) (return-mv m))",
        "expired",
    );
    reject(
        "(block entry (set a (nil)) (values m (a)) (vector b ()) (return-mv m))",
        "expired",
    );
    reject(
        r#"(region r catch nil land)
       (block entry (set a (nil)) (set x (word 0)) (enter r (a))
         (alloc-sequence b simple-vector x a) (leave r) (return ()))
       (block land (landing r m) (return (b)))"#,
        "not initialized",
    );
}

#[test]
fn indexed_objects_initialize_all_fields_and_hide_rack_and_callable_layouts() {
    let text = include_str!("fixtures/lir-objects.lisp-expr");
    check_object_results(
        text,
        10,
        "10\n(42)\n(43)\n99\n99\n(43)\n8\n(42)\n1\n(42)\n1\n",
    );
    for (from, to, error) in [
        (
            "structure structure count initial",
            "structure structure class initial",
            "expected Word",
        ),
        (
            "count stamp nil initial",
            "count count nil initial",
            "expected Obj",
        ),
        (
            "(structure-slot-set structure index b)",
            "(structure-slot-set structure index)",
            "arity",
        ),
        (
            "(instance-slot-set instance index b)",
            "(instance-slot-set instance class b)",
            "expected Word",
        ),
        (
            "(instance-rack-set callable rack)",
            "(instance-rack-set callable count)",
            "expected Obj",
        ),
    ] {
        assert!(
            compile(&text.replace(from, to))
                .unwrap_err()
                .contains(error)
        );
    }
    reject(
        "(block e (set a (nil)) (set x (word 0)) (values m (a)) (alloc-structure b a x a) (return-mv m))",
        "expired",
    );
}

#[test]
fn producer_allocations_use_backend_owned_allocator_imports() {
    let source = |imports: &str, allocation: &str| {
        format!(
            r#"(module "allocation" (init "entry") {imports}
      (data "entry" (static-function "run")) (func "run" (vars (r obj))
        (block e {allocation} (return r 1))))"#
        )
    };
    let short = format!("(alloc-fixed r {} (0 0) nil)", packet::schema::CLASS_CONS);
    let long = format!(
        "(alloc-fixed r {} (0 0) \"kiln_rt_alloc\" nil)",
        packet::schema::CLASS_CONS
    );
    let parse = |text: &str| kiln_cg::kir::parse_module(&sexp::parse_one(text).unwrap());
    let a = parse(&source("", &short)).unwrap();
    let b = parse(&source(
        r#"(import-func "kiln_rt_alloc" 3 1 unwinds) (import-data "kiln_nil")"#,
        &long,
    ))
    .unwrap();
    assert_eq!(format!("{a:?}"), format!("{b:?}"));
    assert!(
        parse(&source(
            r#"(import-func "kiln_rt_alloc" 2 1 unwinds)"#,
            &short
        ))
        .unwrap_err()
        .contains("allocation signature")
    );
}

#[test]
fn runtime_services_own_safepoints_callbacks_and_leaf_transfer_effects() {
    let text = include_str!("fixtures/lir-runtime.lisp-expr");
    let module = compile(text).unwrap();
    let gc = module
        .import_funcs
        .iter()
        .find(|f| f.name == "kiln_rt_gc")
        .unwrap();
    assert!(gc.unwinds && gc.params == 1 && gc.returns == 1);
    let hash = module
        .import_funcs
        .iter()
        .find(|f| f.name == "kiln_rt_identity_hash")
        .unwrap();
    assert!(!hash.unwinds && hash.params == 2 && hash.returns == 1);
    check_object_results(text, 5, "5\n(42)\n1\n(42)\n(42)\n1\n");
    reject(
        "(block e (runtime a gc ()) (return-mv m))",
        "not initialized",
    );
    reject(
        "(block e (set a (nil)) (values m (a)) (runtime b gc ()) (return-mv m))",
        "expired",
    );
    assert!(
        compile(&source(
            "(block e (set a (nil)) (values m (a)) (runtime b gc-count ()) (return-mv m))"
        ))
        .is_ok()
    );
    reject(
        "(block e (runtime a gc-count (a)) (return (a)))",
        "too many",
    );
    reject("(block e (runtime a fd-read ()) (return (a)))", "arity");
    reject(
        "(block e (runtime a arbitrary-native-entry ()) (return (a)))",
        "unknown runtime",
    );
    reject(
        r#"(region r catch nil land)
        (block e (set a (nil)) (enter r (a)) (runtime b gc ()) (leave r) (return ()))
        (block land (landing r m) (return ()))"#,
        "runtime region",
    );
    reject(
        r#"(region r catch nil land)
        (block e (set a (nil)) (enter r (a)) (runtime b gc () (region r)) (leave r) (return ()))
        (block land (landing r m) (return (b)))"#,
        "not initialized",
    );
    let malformed = sexp::parse_one(
        r#"(module "bad" (init "f")
        (import-func "kiln_rt_gc_count" 2 1)
        (data "f" (static-function "run")) (func "run" (vars (r obj))
          (block e (runtime-op r gc-count () nil) (return r 1))))"#,
    )
    .unwrap();
    assert!(
        kiln_cg::kir::parse_module(&malformed)
            .unwrap_err()
            .contains("requires the signature")
    );
}

#[test]
fn fatal_errors_use_a_backend_owned_terminating_runtime_call() {
    let text = source("(block e (set a (fixnum 42)) (set x (word 4)) (fatal-error x a (loc 1 2)))");
    let module = compile(&text).unwrap();
    assert!(module.funcs[0].blocks.iter().flat_map(|b| &b.stmts).any(|s| matches!(s,kiln_cg::kir::Stmt::CallRt {name,results,handler:None,loc:Some((1,2)),..} if name=="kiln_rt_error" && results.is_empty())));
    reject("(block e (set a (nil)) (fatal-error a a))", "expected Word");
    reject(
        "(block e (set a (nil)) (fatal-error x a))",
        "not initialized",
    );
    let temp = Temp::new();
    let program = temp.write("fatal.lir", text);
    let support=temp.write("support.kir",r#"(module "fatal-support" (init "noop-object")
      (data "noop-object" (static-function "noop")) (data "failure-object" (static-function "failure"))
      (data "kiln_sym_KILN_2E_KERNEL_3A__25_STACK_2D_EXHAUSTED" (static-symbol 0 0 (object-data "failure-object" general) 0 0 0))
      (data "kiln_sym_KILN_2E_KERNEL_3A__25_RUNTIME_2D_ERROR" (static-symbol 0 0 (object-data "failure-object" general) 0 0 0))
      (func "failure" (block e (trap))) (func "kiln_undefined_function" (block e (trap)))
      (func "noop" (block e (return 0 1))))"#);
    let output = Command::new(env!("CARGO_BIN_EXE_kiln-cg"))
        .arg("jit")
        .arg(program)
        .arg(support)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("42 is not of type LIST"));
}

#[test]
fn list_values_and_reverse_accumulation_check_types_and_expire_views() {
    compile(&source("(block e (set a (nil)) (values-from-list m a) (mv-push b m a) (values-from-list n b) (return-mv n))")).unwrap();
    reject(
        "(block e (set a (nil)) (values-from-list m a) (mv-push b m a) (return-mv m))",
        "view",
    );
    reject(
        "(block e (set a (nil)) (values-from-list a a) (return (a)))",
        "expected Mv",
    );
    reject(
        "(block e (set a (nil)) (values m (a)) (mv-push b m x) (return (b)))",
        "expected Obj",
    );
}

#[test]
fn list_value_expansions_expose_exception_edges_before_results_exist() {
    reject(
        r#"(region r catch nil land)
        (block e (set a (nil)) (enter r (a)) (values m (a))
          (mv-push b m a) (leave r) (return (b)))
        (block land (landing r n) (return (b)))"#,
        "not initialized",
    );
    reject(
        r#"(region r catch nil land)
        (block e (set a (nil)) (enter r (a)) (values-from-list m a)
          (leave r) (return-mv m))
        (block land (landing r n) (return-mv m))"#,
        "not initialized",
    );
}

#[test]
fn poll_expansion_owns_runtime_signature_and_entry_retry() {
    let parse = |mode: &str| {
        kiln_cg::kir::parse_module(
            &sexp::parse_one(&format!(
                "(module \"poll\" (init \"f\") (func \"f\" (block e (poll {mode} nil) (return 0 1))))"
            ))
            .unwrap(),
        )
    };
    let module = parse("entry-retry").unwrap();
    let retry = module
        .funcs
        .iter()
        .find(|f| f.name == "kiln_poll_retry")
        .unwrap();
    assert!(module.shared.contains(&retry.name));
    assert_eq!(
        retry
            .vars
            .iter()
            .filter(|(n, k)| n.starts_with("saved_arg") && *k == kiln_cg::kir::VarKind::Obj)
            .count(),
        kiln_cg::kir::REG_ARGS
    );
    let poll = module
        .import_funcs
        .iter()
        .find(|f| f.name == "kiln_rt_poll")
        .unwrap();
    assert!(poll.unwinds && poll.params == 2 && poll.returns == 1);
    let image = parse("entry-retry-image").unwrap();
    assert_eq!(image.funcs.len(), 1);
    assert!(image.import_data.iter().any(|n| n == "kiln_poll_retry"));
    assert!(parse("unknown").is_err());
    let bad = sexp::parse_one("(module \"poll\" (init \"f\") (import-func \"kiln_rt_poll\" 1 1) (func \"f\" (block e (poll loop nil) (return 0 1))))").unwrap();
    assert!(
        kiln_cg::kir::parse_module(&bad)
            .unwrap_err()
            .contains("poll signature")
    );
}

#[test]
fn receive_prefix_checks_capacity_and_destination_aliases() {
    let parse = |outputs: &str, count: &str| {
        kiln_cg::kir::parse_module(&sexp::parse_one(&format!(
        "(module \"entry\" (init \"f\") (func \"f\" (vars (a obj) (n raw)) (block e (receive-prefix ({outputs}) {count}) (return a 1))))"
    )).unwrap())
    };
    let module = parse("a", "n").unwrap();
    assert!(module.import_data.iter().any(|n| n == "kiln_nil"));
    assert!(module.import_funcs.is_empty());
    assert!(parse("a a", "n").unwrap_err().contains("receive prefix"));
    assert!(parse("a", "a").unwrap_err().contains("receive prefix"));
    let names = (0..1025)
        .map(|i| format!("a{i}"))
        .collect::<Vec<_>>()
        .join(" ");
    assert!(parse(&names, "n").unwrap_err().contains("receive prefix"));
}

#[test]
fn object_cells_and_literal_tables_supply_roots_and_semantic_debug_references() {
    let module = kiln_cg::kir::parse_module(
        &sexp::parse_one(
            r#"(module "slots" (init "f")
        (literal-table 2) (object-cell "saved" 0)
        (func "f" (vars (a obj)) (debug-literal 1)
          (block e (set a (literal-ref 0)) (cell-set "saved" a)
            (set a (cell-ref "saved")) (return a 1))))"#,
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(module.roots.len(), 3);
    assert!(module.roots.contains(&("saved".into(), 0)));
    assert!(
        matches!(&module.funcs[0].debug,Some(kiln_cg::kir::DebugRef::Indirect(name,8)) if name=="kiln_literals")
    );
    assert!(kiln_cg::lir::cells::offset(usize::MAX).is_err());
    assert!(kiln_cg::lir::cells::offset(packet::schema::MAX_BYTES as usize / 8).is_err());
    let empty = kiln_cg::kir::parse_module(
        &sexp::parse_one(
            r#"(module "empty" (init "f") (literal-table 0) (func "f" (block e (return 0 0))))"#,
        )
        .unwrap(),
    )
    .unwrap();
    assert!(empty.roots.is_empty());
    assert_eq!(empty.data.len(), 1);
}

#[test]
fn builtin_declarations_define_shared_entries_and_keep_code_addresses_private() {
    let text = r#"(lir-module "builtins" (init "run")
      (builtin undefined-function file) (builtin undefined-setf-function file)
      (builtin funcallable-trampoline file) (builtin funcallable-unset file)
      (constants (symbol "TEST" "MISSING"))
      (function "run" (vars (s obj) (f obj) (a obj) (b obj) (x word))
        (block e (set s (constant 0)) (set f (field-ref symbol.function s))
          (set x (undefined-function-p f)) (set a (fixnum-tag x))
          (set f (field-ref symbol.setf-function s)) (set x (undefined-function-p f))
          (set b (fixnum-tag x)) (runtime s gc ()) (return (a b)))))"#;
    let module = compile(text).unwrap();
    assert!(
        module
            .funcs
            .iter()
            .any(|f| f.name == "kiln_undefined_function")
    );
    assert!(
        !module
            .import_data
            .iter()
            .any(|n| n == "kiln_undefined_function")
    );
    check_object_results(text, 2, "2\n1\n1\n");
    assert!(
        compile(&text.replace(
            "(builtin undefined-function file)",
            "(builtin undefined-function file) (builtin undefined-function image)"
        ))
        .unwrap_err()
        .contains("duplicate builtin")
    );
    assert!(
        compile(&text.replace("undefined-function file", "unknown file"))
            .unwrap_err()
            .contains("unknown backend builtin")
    );
    let image = compile(&text.replace(" file)", " image)")).unwrap();
    assert!(
        !image
            .funcs
            .iter()
            .any(|f| f.name == "kiln_undefined_function")
    );
    assert!(
        image
            .import_data
            .iter()
            .any(|n| n == "kiln_undefined_function")
    );
}

#[test]
fn checked_fixnum_arithmetic_checks_outputs_aliases_and_preserves_value_views() {
    let text = r#"(lir-module "checked" (init "run")
      (function "run" (vars (a obj) (b obj) (c obj) (first obj) (second obj) (ok obj) (sub-ok obj) (add obj) (sub obj) (mul obj) (x word) (m mv))
        (block e (set a (fixnum 40)) (set b (fixnum 2))
          (fixnum-add-ovf a x a b) (set ok (fixnum-tag x)) (values m (a b))
          (fixnum-sub-ovf b x a b) (set sub-ok (fixnum-tag x)) (set second b) (set first (mv-ref m 0))
          (set a (fixnum 4611686018427387903)) (set b (fixnum 1))
          (fixnum-add-ovf c x a b) (set add (fixnum-tag x))
          (set a (fixnum -4611686018427387904))
          (fixnum-sub-ovf c x a b) (set sub (fixnum-tag x))
          (set a (fixnum 4611686018427387903)) (set b (fixnum 2))
          (fixnum-mul-ovf c x a b) (set mul (fixnum-tag x))
          (runtime c gc ()) (return (first second ok sub-ok add sub mul)))))"#;
    check_object_results(text, 7, "7\n42\n40\n0\n0\n1\n1\n1\n");
    reject(
        "(block e (set a (fixnum 1)) (fixnum-add-ovf b x a f) (return (b)))",
        "not initialized",
    );
    reject(
        "(block e (set a (fixnum 1)) (fixnum-add-ovf b f a a) (return (b)))",
        "expected Word",
    );
    compile(&source("(block e (set a (fixnum 1)) (fixnum-mul-ovf b x a a) (set a (fixnum-tag x)) (return (a b)))")).unwrap();
}

#[test]
fn scalar_operations_preserve_signed_arithmetic_shifts_and_float_payloads() {
    let text = include_str!("fixtures/lir-scalars.lisp-expr");
    check_object_results(
        text,
        22,
        "22\n-3\n-2\n5\n-17\n-22\n16\n-20\n-9\n0\n1\n-2\n-4\n-3\n-2\n1\n1\n1\n-1\n0\n1\n0\n1\n",
    );
    reject(
        "(block e (set a (fixnum 1)) (set x (word-shift-left a a)) (return (a)))",
        "expected Word",
    );
    reject(
        "(block e (set x (word 1)) (set a (fixnum-logand x x)) (return (a)))",
        "expected Obj",
    );
    reject(
        "(block e (set d (f64 0)) (set x (word-add d d)) (return ()))",
        "expected Word",
    );
    reject(
        "(block e (set x (word 1)) (set d (f64-add x x)) (return ()))",
        "expected F64",
    );
    reject(
        "(block e (set x (word 1)) (set a (single-float-tag x x)) (return (a)))",
        "expected 1 operands",
    );
}

#[test]
fn moving_value_views_renames_the_borrow_and_expires_the_source() {
    compile(&source(
        "(block e (set a (nil)) (values m (a a)) (mv-move n m) (return-mv n))",
    ))
    .unwrap();
    reject(
        "(block e (values m ()) (mv-move n m) (return-mv m))",
        "expired",
    );
    reject("(block e (mv-move n m) (return-mv n))", "not initialized");
    reject(
        "(block e (values m ()) (mv-move a m) (return (a)))",
        "expected Mv",
    );
    compile(&source(
        "(block e (values m ()) (mv-move m m) (return-mv m))",
    ))
    .unwrap();
}

#[test]
fn known_calls_validate_names_and_lower_to_direct_entries() {
    let module = compile(&source(
        r#"(block e (set f (function "body")) (call-known m "body" f ()) (return-mv m))"#,
    ))
    .unwrap();
    assert!(module.funcs.iter().flat_map(|f|&f.blocks).flat_map(|b|&b.stmts).any(|s| matches!(s,kiln_cg::kir::Stmt::CallLisp {entry:kiln_cg::kir::Expr::Addr(name,0),..} if name=="body")));
    reject(
        r#"(block e (set f (function "body")) (call-known m "missing" f ()) (return-mv m))"#,
        "entry is not defined",
    );
}
