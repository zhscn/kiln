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
    // KILN_CG_OPT: Cranelift's opt_level (default "speed"). KILN_VERIFY=1
    // runs Cranelift's IR verifier on every function (slow on the large
    // modules).
    let opt = std::env::var("KILN_CG_OPT").unwrap_or_else(|_| "speed".to_string());
    let verify = std::env::var("KILN_VERIFY").is_ok_and(|v| v == "1");
    set(&mut flags, "opt_level", &opt)?;
    set(&mut flags, "preserve_frame_pointers", "true")?;
    set(&mut flags, "is_pic", if pic { "true" } else { "false" })?;
    set(&mut flags, "enable_verifier", if verify { "true" } else { "false" })?;
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

/// Loads KIR files and merges them into one module; their init functions
/// run in the order given.
fn load_all(files: &[&String]) -> Result<kir::Module, String> {
    let modules = files.iter().map(|f| load(f)).collect::<Result<Vec<_>, _>>()?;
    kir::merge(modules)
}

fn run_jit(kir: &kir::Module, opts: &Options) -> Result<i32, String> {
    let mut builder = JITBuilder::with_isa(isa(false)?, default_libcall_names());
    for (name, ptr) in kiln_rt::symbols() {
        builder.symbol(name, ptr);
    }
    let mut module = JITModule::new(builder);
    let t = std::time::Instant::now();
    let out = codegen::compile(&mut module, kir, opts)?;
    module.finalize_definitions().map_err(|e| e.to_string())?;
    if std::env::var("KILN_TIME").is_ok() {
        eprintln!("kiln-cg: compiled in {:?}", t.elapsed());
    }
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
    let inits: Vec<u64> = out
        .inits
        .iter()
        .map(|id| module.get_finalized_data(*id).0 as u64 + kiln_rt::object::TAG_GENERAL)
        .collect();
    let roots: Vec<usize> = out
        .roots
        .iter()
        .map(|(id, off)| module.get_finalized_data(*id).0 as usize + *off as usize)
        .collect();
    let info = kiln_rt::ModuleInfo {
        enter: unsafe { std::mem::transmute::<*const u8, kiln_rt::EnterFn>(enter) },
        inits: inits.as_ptr(),
        ninits: inits.len() as u64,
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
    // kiln-cg jit A.kir B.kir ...  |  kiln-cg obj A.kir B.kir ... -o OUT.o
    let result = match pos.split_first() {
        Some((cmd, rest)) if cmd.as_str() == "jit" && !rest.is_empty() => {
            {
                let t = std::time::Instant::now();
                let m = load_all(rest);
                if std::env::var("KILN_TIME").is_ok() {
                    eprintln!("kiln-cg: loaded in {:?}", t.elapsed());
                }
                m.and_then(|m| run_jit(&m, &opts))
            }
        }
        Some((cmd, rest)) if cmd.as_str() == "obj" && rest.len() >= 3 && rest[rest.len() - 2] == "-o" => {
            let (files, out) = rest.split_at(rest.len() - 2);
            load_all(files).and_then(|m| write_obj(&m, &opts, out[1]).map(|_| 0))
        }
        _ => Err("usage: kiln-cg jit FILE.kir... | kiln-cg obj FILE.kir... -o FILE.o [--dump-clif]".into()),
    };
    match result {
        Ok(code) => ExitCode::from(code as u8),
        Err(e) => {
            eprintln!("kiln-cg: {e}");
            ExitCode::from(2)
        }
    }
}
