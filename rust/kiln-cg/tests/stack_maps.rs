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
      (data "kiln_nil" (words 0))
      (import-func "opaque" 0 0)
      (func "body" (vars (temp obj) (copy obj) (saved obj) (overflow raw)) (slots)
        (block entry
          (set temp (and a0 -2))
          (set copy temp)
          (fixnum-add-ovf saved overflow copy 2)
          (fixnum-sub-ovf copy overflow saved 2)
          (set temp (mul a1 copy))
          (fixnum-mul-ovf saved overflow a1 temp)
          (call-rt "opaque" () () nil)
          (return saved 1)))
      (func "fixed-symbol" (vars (value obj)) (slots)
        (block entry
          (set value (addr "kiln_nil" 5))
          (call-rt "opaque" () () nil)
          (return value 1)))
      (func "fixed-or-dynamic" (vars (value obj)) (slots)
        (block entry
          (set value (addr "kiln_nil" 5))
          (br (eq a0 0) join dynamic))
        (block dynamic
          (set value a1)
          (jump join))
        (block join
          (call-rt "opaque" () () nil)
          (return value 1)))
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
      (func "mixed" (vars (maybe-object obj) (visible obj 0) (saved obj) (overflow raw)) (slots) (debug 0)
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
          (add-ovf saved overflow maybe-object 0)
          (call-rt "opaque" () () nil (loc 0 1))
          (return (xor saved visible) 1))))"#;
    let input = kir::parse_module(&sexp::parse_one(source).unwrap()).unwrap();
    let output =
        codegen::compile(&mut module, &input, &codegen::Options { dump_clif: false }).unwrap();
    let mut root_counts: Vec<_> = output.stackmaps.iter().map(|map| map.offsets.len()).collect();
    root_counts.sort_unstable();
    assert_eq!(root_counts, [1, 2]);
    assert!(output.debug.iter().any(|record| !record.sites.is_empty()));
}
