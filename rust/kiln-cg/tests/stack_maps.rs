use cranelift_codegen::settings::{self, Configurable};
use cranelift_jit::{JITBuilder, JITModule};
use cranelift_module::default_libcall_names;
use kiln_cg::{codegen, kir, sexp};

#[test]
fn immediate_temporaries_need_stack_slots_only_when_debug_visible() {
    let mut flags = settings::builder();
    flags.set("enable_verifier", "true").unwrap();
    flags.set("preserve_frame_pointers", "true").unwrap();
    let isa = cranelift_native::builder()
        .unwrap()
        .finish(settings::Flags::new(flags))
        .unwrap();
    let mut module = JITModule::new(JITBuilder::with_isa(isa, default_libcall_names()));
    let source = r#"(module "immediate-roots"
      (init "init") (data "init" (words 258 (func "body")))
      (import-func "opaque" 0 0)
      (func "body" (vars (temp obj) (copy obj) (saved obj)) (slots)
        (block entry
          (set temp (and a0 -2))
          (set copy temp)
          (set saved copy)
          (call-rt "opaque" () () nil)
          (return saved 1)))
      (func "rotate" (vars (left obj) (right obj) (saved obj) (remaining raw)) (slots)
        (block entry
          (set left (and a0 -2))
          (set right (and a1 -2))
          (set remaining nargs)
          (jump check))
        (block check
          (br (eq remaining 0) done rotate))
        (block rotate
          (set saved left)
          (set left (add right 2))
          (set right saved)
          (set remaining (sub remaining 1))
          (jump check))
        (block done
          (call-rt "opaque" () () nil)
          (return left 1)))
      (func "mixed" (vars (maybe-object obj) (visible obj 0) (saved obj)) (slots) (debug 0)
        (block entry
          (set visible (fixnum-tag a1))
          (br (eq a0 0) integer object))
        (block integer
          (set maybe-object 2)
          (jump join))
        (block object
          (set maybe-object a2)
          (jump join))
        (block join
          (set saved (or maybe-object 0))
          (call-rt "opaque" () () nil (loc 0 1))
          (return (xor saved visible) 1))))"#;
    let input = kir::parse_module(&sexp::parse_one(source).unwrap()).unwrap();
    let output =
        codegen::compile(&mut module, &input, &codegen::Options { dump_clif: false }).unwrap();
    assert_eq!(output.stackmaps.len(), 1);
    assert_eq!(output.stackmaps[0].offsets.len(), 2);
    assert!(output.debug.iter().any(|record| !record.sites.is_empty()));
}
