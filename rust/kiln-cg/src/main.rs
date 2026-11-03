//! kiln-cg: compiles KIR produced by the Lisp compiler.
//!
//!   kiln-cg jit FILE.kir [--dump-clif]          compile in memory and run
//!   kiln-cg obj FILE.kir -o FILE.o [--dump-clif] write an object file
//!
//! Object files are linked with libkiln_launcher.a to make an executable.

mod codegen;
mod kir;
mod sexp;

use codegen::Options;
use cranelift_codegen::isa::OwnedTargetIsa;
use cranelift_codegen::settings::{self, Configurable};
use cranelift_jit::{JITBuilder, JITModule};
use cranelift_module::default_libcall_names;
use cranelift_object::{ObjectBuilder, ObjectModule};
use kiln_rt::unwind::CallSiteRecord;
use std::process::ExitCode;

fn isa(pic: bool) -> Result<OwnedTargetIsa, String> {
    let mut flags = settings::builder();
    let set = |f: &mut settings::Builder, k: &str, v: &str| f.set(k, v).map_err(|e| e.to_string());
    set(&mut flags, "opt_level", "speed")?;
    set(&mut flags, "preserve_frame_pointers", "true")?;
    set(&mut flags, "is_pic", if pic { "true" } else { "false" })?;
    set(&mut flags, "enable_verifier", "true")?;
    let isa_builder = cranelift_native::builder()?;
    isa_builder
        .finish(settings::Flags::new(flags))
        .map_err(|e| e.to_string())
}

fn load(path: &str) -> Result<kir::Module, String> {
    let src = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    let s = sexp::parse_one(&src).map_err(|e| format!("{path}: {e}"))?;
    kir::parse_module(&s).map_err(|e| format!("{path}: {e}"))
}

fn run_jit(kir: &kir::Module, opts: &Options) -> Result<i32, String> {
    let mut builder = JITBuilder::with_isa(isa(false)?, default_libcall_names());
    for (name, ptr) in kiln_rt::symbols() {
        builder.symbol(name, ptr);
    }
    let mut module = JITModule::new(builder);
    let out = codegen::compile(&mut module, kir, opts)?;
    module.finalize_definitions().map_err(|e| e.to_string())?;
    let records: Vec<CallSiteRecord> = out
        .callsites
        .iter()
        .map(|cs| CallSiteRecord {
            func: module.get_finalized_function(cs.func) as usize,
            ret_off: cs.ret_off,
            handler_off: cs.handler_off,
            frame_offset: cs.frame_offset,
            _pad: 0,
        })
        .collect();
    let maps: Vec<kiln_rt::gc::StackMapRecord> = out
        .stackmaps
        .iter()
        .map(|sm| kiln_rt::gc::StackMapRecord {
            func: module.get_finalized_function(sm.func) as usize,
            ret_off: sm.ret_off,
            count: sm.offsets.len() as u32,
            offsets: sm.offsets.as_ptr(),
        })
        .collect();
    let enter = module.get_finalized_function(out.enter);
    let (init, _) = module.get_finalized_data(out.init_data);
    let roots: Vec<usize> = out
        .roots
        .iter()
        .map(|(id, off)| module.get_finalized_data(*id).0 as usize + *off as usize)
        .collect();
    let info = kiln_rt::ModuleInfo {
        enter: unsafe { std::mem::transmute::<*const u8, kiln_rt::EnterFn>(enter) },
        init_fobj: init as u64 + kiln_rt::object::TAG_GENERAL,
        callsites: records.as_ptr(),
        ncallsites: records.len() as u64,
        stackmaps: maps.as_ptr(),
        nstackmaps: maps.len() as u64,
        roots: roots.as_ptr(),
        nroots: roots.len() as u64,
    };
    Ok(unsafe { kiln_rt::run_module(&info) })
}

fn write_obj(kir: &kir::Module, opts: &Options, out_path: &str) -> Result<(), String> {
    let builder = ObjectBuilder::new(isa(true)?, kir.name.as_bytes(), default_libcall_names())
        .map_err(|e| e.to_string())?;
    let mut module = ObjectModule::new(builder);
    let out = codegen::compile(&mut module, kir, opts)?;
    codegen::emit_module_info(&mut module, &out)?;
    let product = module.finish();
    let bytes = product.emit().map_err(|e| e.to_string())?;
    std::fs::write(out_path, bytes).map_err(|e| format!("{out_path}: {e}"))
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let dump_clif = args.iter().any(|a| a == "--dump-clif");
    let opts = Options { dump_clif };
    let pos: Vec<&String> = args.iter().filter(|a| !a.starts_with("--")).collect();
    let result = match pos.as_slice() {
        [cmd, file] if cmd.as_str() == "jit" => load(file).and_then(|m| run_jit(&m, &opts)),
        [cmd, file, o, out] if cmd.as_str() == "obj" && o.as_str() == "-o" => {
            load(file).and_then(|m| write_obj(&m, &opts, out).map(|_| 0))
        }
        _ => Err("usage: kiln-cg jit FILE.kir | kiln-cg obj FILE.kir -o FILE.o [--dump-clif]".into()),
    };
    match result {
        Ok(code) => ExitCode::from(code as u8),
        Err(e) => {
            eprintln!("kiln-cg: {e}");
            ExitCode::from(2)
        }
    }
}
