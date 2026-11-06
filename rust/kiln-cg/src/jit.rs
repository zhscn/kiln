//! In-memory compilation: whole programs (`kiln-cg jit`) and code compiled
//! into a running image (`kiln_rt_jit`, docs/11 §11).

use crate::codegen::{self, Options, Output, Ref};
use crate::kir;
use cranelift_codegen::isa::OwnedTargetIsa;
use cranelift_codegen::settings::{self, Configurable};
use cranelift_jit::{JITBuilder, JITModule};
use cranelift_module::default_libcall_names;
use kiln_rt::context::Context;
use kiln_rt::unwind::CallSiteRecord;

/// The non-PIC ISA, made once: code compiled into a running image is
/// compiled with it, module by module.
fn jit_isa() -> Result<OwnedTargetIsa, String> {
    static ISA: std::sync::OnceLock<Result<OwnedTargetIsa, String>> = std::sync::OnceLock::new();
    ISA.get_or_init(|| isa(false)).clone()
}

pub fn isa(pic: bool) -> Result<OwnedTargetIsa, String> {
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

/// Where the code and data of a module go.
pub enum Memory {
    /// A region of this many bytes reserved for the module.
    Own(usize),
    /// The region shared by the modules compiled into a running image.
    Shared,
}

/// The region for code compiled into a running image: one, so that
/// later modules lie above earlier ones, and the runtime's tables of call
/// sites and stack maps, sorted by address, grow at the end. Reserved, not
/// committed; never freed.
static SHARED_ARENA: std::sync::Mutex<Option<cranelift_jit::ArenaMemoryProvider>> =
    std::sync::Mutex::new(None);

struct SharedArena;

impl cranelift_jit::JITMemoryProvider for SharedArena {
    fn allocate(
        &mut self,
        size: usize,
        align: u64,
        kind: cranelift_jit::JITMemoryKind,
    ) -> std::io::Result<*mut u8> {
        let mut arena = SHARED_ARENA.lock().unwrap();
        if arena.is_none() {
            *arena = Some(cranelift_jit::ArenaMemoryProvider::new_with_size(16 << 30).map_err(std::io::Error::other)?);
        }
        arena.as_mut().unwrap().allocate(size, align, kind)
    }

    unsafe fn free_memory(&mut self) {}

    fn finalize(
        &mut self,
        branch_protection: cranelift_jit::BranchProtection,
    ) -> cranelift_module::ModuleResult<()> {
        match SHARED_ARENA.lock().unwrap().as_mut() {
            Some(arena) => arena.finalize(branch_protection),
            None => Ok(()),
        }
    }
}

/// Code compiled into memory, with its tables registered with the runtime.
pub struct Loaded {
    pub module: JITModule,
    pub out: Output,
}

/// Compiles `kir` into `memory` (all code and data in one region, so that
/// PC-relative references between them stay within 32 bits), and registers its call sites, stack maps, static
/// roots and exports with the runtime. Imports are the runtime's functions
/// and what loaded modules export.
pub fn load(kir: &kir::Module, opts: &Options, memory: Memory) -> Result<Loaded, String> {
    let mut builder = JITBuilder::with_isa(jit_isa()?, default_libcall_names());
    match memory {
        Memory::Own(reserve) => builder.memory_provider(Box::new(
            cranelift_jit::ArenaMemoryProvider::new_with_size(reserve)
                .map_err(|e| format!("cannot reserve the JIT's memory: {e}"))?,
        )),
        Memory::Shared => builder.memory_provider(Box::new(SharedArena)),
    };
    for (name, ptr) in kiln_rt::symbols() {
        builder.symbol(name, ptr);
    }
    builder.symbol("kiln_rt_jit", kiln_rt_jit as *const u8);
    builder.symbol_lookup_fn(Box::new(|name| kiln_rt::exported(name).map(|a| a as *const u8)));
    let mut module = JITModule::new(builder);
    let out = codegen::compile(&mut module, kir, opts)?;
    module.finalize_definitions().map_err(|e| e.to_string())?;
    let callsites: Vec<CallSiteRecord> = out
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
    // The runtime keeps the offsets: the records point into them.
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
    let roots: Vec<usize> = out
        .roots
        .iter()
        .map(|(id, off)| module.get_finalized_data(*id).0 as usize + *off as usize)
        .collect();
    kiln_rt::register_code(&callsites, &maps, &roots);
    for (name, r) in &out.exports {
        let addr = match r {
            Ref::Func(id) => module.get_finalized_function(*id) as usize,
            Ref::Data(id) => module.get_finalized_data(*id).0 as usize,
        };
        kiln_rt::register_export(name, addr);
    }
    Ok(Loaded { module, out })
}

impl Loaded {
    /// The init function objects, tagged.
    pub fn inits(&self) -> Vec<u64> {
        self.out
            .inits
            .iter()
            .map(|id| self.module.get_finalized_data(*id).0 as u64 + kiln_rt::object::TAG_GENERAL)
            .collect()
    }
}

/// Name of the data object holding the literals of code compiled into the
/// running image: one word per literal, each a static root (lower.lisp).
const LITERALS_NAME: &str = "kiln_literals";

/// Compiles the KIR module in the Lisp string `text` into the running
/// image and returns its init function object, which has not been called.
/// `literals` is a simple vector: its elements are stored into the
/// module's literal words. Returns NIL, after printing the reason, if the
/// KIR cannot be compiled (a bug of the compiler).
///
/// The code is never freed. Nothing allocates in the Lisp heap here, so
/// `text` and `literals` do not move.
///
/// # Safety
/// `text` must be a string and `literals` a simple vector.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_jit(_ctx: *mut Context, text: u64, literals: u64) -> u64 {
    match unsafe { jit_text(text, literals) } {
        Ok(init) => init,
        Err(e) => {
            eprintln!("kiln_rt_jit: {e}");
            kiln_rt::object::nil()
        }
    }
}

unsafe fn jit_text(text: u64, literals: u64) -> Result<u64, String> {
    use kiln_rt::object::{header, header_length, untag};
    let t = std::time::Instant::now();
    let src = unsafe { kiln_rt::object::string_value(text) };
    let s = crate::sexp::parse_one(&src).map_err(|e| e.to_string())?;
    let kir = kir::parse_module(&s)?;
    let loaded = load(&kir, &Options { dump_clif: false }, Memory::Shared)?;
    let n = header_length(unsafe { header(literals) });
    if n > 0 {
        let id = loaded
            .out
            .data
            .get(LITERALS_NAME)
            .ok_or("the module has literals but no literal words")?;
        let (words, size) = loaded.module.get_finalized_data(*id);
        if size < n * 8 {
            return Err("more literals than literal words".into());
        }
        let elements = (untag(literals) + 8) as *const u64;
        for i in 0..n {
            unsafe { *(words as *mut u64).add(i) = *elements.add(i) };
        }
    }
    let inits = loaded.inits();
    if std::env::var("KILN_TIME").is_ok() {
        eprintln!("kiln_rt_jit: {} bytes of KIR in {:?}", src.len(), t.elapsed());
    }
    if std::env::var("KILN_PERF_MAP").is_ok() {
        append_perf_map(&loaded.module);
    }
    // The memory stays: the code is part of the image now.
    std::mem::forget(loaded);
    inits.first().copied().ok_or_else(|| "no init function".into())
}

/// Lines of perf's map (/tmp/perf-PID.map) for the functions of `module`:
/// "START SIZE NAME" in hex. A function's size is up to the next one.
pub fn perf_map_lines(module: &JITModule) -> String {
    use cranelift_module::Module;
    let mut funcs: Vec<(usize, String)> = module
        .declarations()
        .get_functions()
        .filter(|(_, d)| d.linkage.is_definable())
        .map(|(id, d)| (module.get_finalized_function(id) as usize, d.linkage_name(id).into_owned()))
        .collect();
    funcs.sort();
    let mut text = String::new();
    for (i, (start, name)) in funcs.iter().enumerate() {
        let size = funcs.get(i + 1).map_or(4096, |(next, _)| next - start);
        text.push_str(&format!("{start:x} {size:x} {name}\n"));
    }
    text
}

fn append_perf_map(module: &JITModule) {
    use std::io::Write;
    let path = format!("/tmp/perf-{}.map", std::process::id());
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = f.write_all(perf_map_lines(module).as_bytes());
    }
}
