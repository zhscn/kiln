use super::*;

static REGISTRY_TESTS: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[test]
fn diagnostics_preserve_unicode_and_bound_allocation() {
    use crate::packet::schema::*;
    let words = diagnostic_words(CompilationError::new(CompilationStage::Program, "λ🙂"));
    assert_eq!(
        words,
        vec![
            u64::from(DIAGNOSTIC_VERSION) << 1,
            u64::from(DIAGNOSTIC_STAGE_PROGRAM) << 1,
            0,
            0x3bb << 1,
            0x1f642 << 1
        ]
    );
    let text = "λ".repeat(DIAGNOSTIC_MAX_CHARS as usize + 10);
    let words = diagnostic_words(CompilationError::new(CompilationStage::Request, text));
    assert_eq!(words.len(), DIAGNOSTIC_MAX_CHARS as usize + 3);
    assert_eq!(words[2], 2);
}

fn source() -> kir::Module {
    kir::parse_module(&crate::sexp::parse_one(
        r#"(module "publication" (init "publication_root") (data "publication_root" (words 0)) (root "publication_root" 0))"#,
    ).unwrap()).unwrap()
}

#[test]
fn prepared_roots_are_registered_only_when_published() {
    let _guard = REGISTRY_TESTS.lock().unwrap();
    let pending = prepare(
        &source(),
        &Options { dump_clif: false },
        Memory::Own(1 << 20),
    )
    .unwrap();
    let id = pending.out.data["publication_root"];
    let address = pending.module.get_finalized_data(id).0 as usize;
    assert!(!kiln_rt::gc::static_roots().contains(&address));
    let loaded = pending.publish();
    assert!(kiln_rt::gc::static_roots().contains(&address));
    // Published roots and code share the image lifetime.
    std::mem::forget(loaded);
}

#[test]
fn dropping_prepared_code_leaves_no_registered_roots() {
    let _guard = REGISTRY_TESTS.lock().unwrap();
    let pending = prepare(
        &source(),
        &Options { dump_clif: false },
        Memory::Own(1 << 20),
    )
    .unwrap();
    let id = pending.out.data["publication_root"];
    let address = pending.module.get_finalized_data(id).0 as usize;
    drop(pending);
    assert!(!kiln_rt::gc::static_roots().contains(&address));
}
