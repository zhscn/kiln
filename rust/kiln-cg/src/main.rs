//! kiln-cg: compiles KIR produced by the Lisp compiler.
//!
//!   kiln-cg jit FILE.kir [--dump-clif]          compile in memory and run
//!   kiln-cg obj FILE.kir -o FILE.o [--dump-clif] write an object file
//!
//! Object files are linked with libkiln_launcher.a to make an executable.

use kiln_cg::codegen::{self, Options};
use kiln_cg::jit::{self, isa};
use kiln_cg::kir;
use cranelift_module::default_libcall_names;
use cranelift_object::{ObjectBuilder, ObjectModule};
use std::process::ExitCode;

fn load(path: &str) -> Result<kir::Module, String> {
    let src = std::fs::read_to_string(path).map_err(|e| format!("{path}: {e}"))?;
    let s = kiln_cg::sexp::parse_one(&src).map_err(|e| format!("{path}: {e}"))?;
    kir::parse_module(&s).map_err(|e| format!("{path}: {e}"))
}

/// Loads KIR files and merges them into one module; their init functions
/// run in the order given.
fn load_all(files: &[&String]) -> Result<kir::Module, String> {
    let modules = files.iter().map(|f| load(f)).collect::<Result<Vec<_>, _>>()?;
    kir::merge(modules)
}

fn run_jit(kir: &kir::Module, opts: &Options) -> Result<i32, String> {
    let t = std::time::Instant::now();
    // 2 GiB: the kernel and CLOS modules together are large.
    let loaded = jit::load(kir, opts, jit::Memory::Own(1 << 31))?;
    if std::env::var("KILN_TIME").is_ok() {
        eprintln!("kiln-cg: compiled in {:?}", t.elapsed());
    }
    if std::env::var("KILN_PERF_MAP").is_ok() {
        let path = format!("/tmp/perf-{}.map", std::process::id());
        std::fs::write(&path, jit::perf_map_lines(&loaded.module)).map_err(|e| format!("{path}: {e}"))?;
    }
    let inits = loaded.inits();
    let enter = loaded.module.get_finalized_function(loaded.out.enter);
    // The tables are registered already (jit::load); the others are
    // empty (slices made from them need non-null pointers).
    let none = std::ptr::NonNull::dangling().as_ptr();
    let info = kiln_rt::ModuleInfo {
        enter: unsafe { std::mem::transmute::<*const u8, kiln_rt::EnterFn>(enter) },
        inits: inits.as_ptr(),
        ninits: inits.len() as u64,
        callsites: none as *const _,
        ncallsites: 0,
        stackmaps: none as *const _,
        nstackmaps: 0,
        roots: none as *const _,
        nroots: 0,
        exports: none as *const _,
        nexports: 0,
        debug: none as *const _,
        ndebug: 0,
    };
    let code = unsafe { kiln_rt::run_module(&info) };
    std::mem::forget(loaded);
    Ok(code)
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
