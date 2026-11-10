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
    let functions = ["f64-add", "f64-sub", "f64-mul", "f64-div"]
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
