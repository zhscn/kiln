use cranelift_codegen::settings::{self, Configurable};
use cranelift_jit::{JITBuilder, JITModule};
use cranelift_module::default_libcall_names;
use kiln_cg::{codegen, kir, sexp};

#[test]
fn binary64_bit_patterns_compile_with_verification() {
    let mut flags = settings::builder();
    flags.set("enable_verifier", "true").unwrap();
    flags.set("preserve_frame_pointers", "true").unwrap();
    let isa = cranelift_native::builder()
        .unwrap()
        .finish(settings::Flags::new(flags))
        .unwrap();
    let mut module = JITModule::new(JITBuilder::with_isa(isa, default_libcall_names()));
    let functions = ["f64-add", "f64-sub", "f64-mul", "f64-div", "f64-compare"]
        .iter()
        .enumerate()
        .map(|(i, op)| format!("(func \"f{i}\" (vars (bits raw)) (slots) (block entry (set bits ({op} a0 a1)) (return bits 1)))"))
        .collect::<Vec<_>>()
        .join("\n");
    let source = format!(
        "(module \"floats\" (init \"init\") (data \"init\" (words 258 (func \"f0\"))) {functions})"
    );
    let ast = sexp::parse_one(&source).unwrap();
    let input = kir::parse_module(&ast).unwrap();
    codegen::compile(&mut module, &input, &codegen::Options { dump_clif: false }).unwrap();
}

#[test]
fn live_binary64_slots_are_debuggable_and_excluded_from_gc_roots() {
    let mut flags = settings::builder();
    flags.set("enable_verifier", "true").unwrap();
    flags.set("preserve_frame_pointers", "true").unwrap();
    let isa = cranelift_native::builder()
        .unwrap()
        .finish(settings::Flags::new(flags))
        .unwrap();
    let mut module = JITModule::new(JITBuilder::with_isa(isa, default_libcall_names()));
    let source = r#"(module "raw-debug"
      (init "init") (data "init" (words 258 (func "body")))
      (import-func "opaque" 0 0)
      (func "body" (vars (value f64 0)) (slots) (debug 0)
        (block entry
          (set value (f64-add a0 a1))
          (call-rt "opaque" () () nil (loc 0 1))
          (return value 1)))
      (func "mixed" (vars (value f64 0) (object obj 1)) (slots) (debug 0)
        (block entry
          (set object a0)
          (set value (f64-mul a1 a2))
          (call-rt "opaque" () () nil (loc 0 1))
          (return (xor object value) 1))))"#;
    let input = kir::parse_module(&sexp::parse_one(source).unwrap()).unwrap();
    let output =
        codegen::compile(&mut module, &input, &codegen::Options { dump_clif: false }).unwrap();
    assert_eq!(output.stackmaps.len(), 1);
    assert_eq!(output.stackmaps[0].offsets.len(), 1);
    let bytes = &output
        .debug
        .iter()
        .find(|record| !record.sites.is_empty())
        .unwrap()
        .sites;
    let mut words = Vec::new();
    let (mut word, mut shift) = (0u64, 0);
    for byte in bytes {
        word |= u64::from(byte & 127) << shift;
        if byte & 128 == 0 {
            words.push(word);
            word = 0;
            shift = 0;
        } else {
            shift += 7;
        }
    }
    assert_eq!(&words[1..5], &[1, 1, 1, 0]);
}

#[test]
fn binary64_bits_survive_collection_without_becoming_roots() {
    let path = std::env::temp_dir().join(format!("kiln-f64-gc-{}.kir", std::process::id()));
    // The payload has general-object tag bits, so tracing it as a reference
    // would be invalid even though it is a valid floating-point bit pattern.
    std::fs::write(&path, include_str!("fixtures/f64-gc.kir")).unwrap();
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_kiln-cg"))
        .arg("jit")
        .arg(&path)
        .env("KILN_VERIFY", "1")
        .output()
        .unwrap();
    std::fs::remove_file(path).unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}
