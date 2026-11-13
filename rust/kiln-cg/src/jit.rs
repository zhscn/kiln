//! In-memory compilation: whole programs (`kiln-cg jit`) and code compiled
//! into a running image (`kiln_rt_jit`).

use crate::codegen::{self, DebugInfo, Options, Output, Ref};
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
    set(
        &mut flags,
        "enable_verifier",
        if verify { "true" } else { "false" },
    )?;
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

/// Allocates the code and data of modules compiled into a running image
/// from the runtime's code region (kiln_rt::code), at a fixed address, so
/// that heap images can hold them. Later modules lie above
/// earlier ones, so the runtime's tables of call sites and stack maps,
/// sorted by address, grow at the end. Never freed.
///
/// Each kind of memory is allocated from a chunk of pages of its own;
/// a module's finalization applies the chunks' protections, and the next
/// module starts new chunks.
static SHARED: std::sync::Mutex<SharedState> =
    std::sync::Mutex::new(SharedState { chunks: Vec::new() });

struct Chunk {
    prot: kiln_rt::code::Prot,
    start: usize,
    cursor: usize,
    end: usize,
}

struct SharedState {
    /// The chunks of the module being compiled.
    chunks: Vec<Chunk>,
}

struct SharedArena;

fn prot(kind: &cranelift_jit::JITMemoryKind) -> kiln_rt::code::Prot {
    use cranelift_jit::JITMemoryKind;
    match kind {
        JITMemoryKind::Executable => kiln_rt::code::Prot::ReadExecute,
        JITMemoryKind::ReadOnly => kiln_rt::code::Prot::ReadOnly,
        JITMemoryKind::Writable => kiln_rt::code::Prot::ReadWrite,
    }
}

impl cranelift_jit::JITMemoryProvider for SharedArena {
    fn allocate(
        &mut self,
        size: usize,
        align: u64,
        kind: cranelift_jit::JITMemoryKind,
    ) -> std::io::Result<*mut u8> {
        let align = align.max(1) as usize;
        let prot = prot(&kind);
        let mut state = SHARED.lock().unwrap();
        if let Some(c) = state.chunks.iter_mut().rev().find(|c| c.prot == prot) {
            let at = c.cursor.next_multiple_of(align);
            if at + size <= c.end {
                c.cursor = at + size;
                return Ok(at as *mut u8);
            }
        }
        let len = size
            .next_multiple_of(kiln_rt::code::PAGE)
            .max(16 * kiln_rt::code::PAGE);
        let start = kiln_rt::code::allocate_pages(len).map_err(std::io::Error::other)?;
        state.chunks.push(Chunk {
            prot,
            start,
            cursor: start + size,
            end: start + len,
        });
        Ok(start as *mut u8)
    }

    unsafe fn free_memory(&mut self) {}

    fn finalize(
        &mut self,
        _branch_protection: cranelift_jit::BranchProtection,
    ) -> cranelift_module::ModuleResult<()> {
        let chunks = std::mem::take(&mut SHARED.lock().unwrap().chunks);
        for c in chunks {
            kiln_rt::code::add_segment(c.start, c.end - c.start, c.prot).map_err(|e| {
                cranelift_module::ModuleError::Allocation {
                    err: std::io::Error::other(e),
                }
            })?;
        }
        // x86-64 needs no instruction cache maintenance.
        Ok(())
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
    builder.symbol(
        "kiln_rt_compile_packet",
        kiln_rt_compile_packet as *const u8,
    );
    builder.symbol(
        "kiln_rt_compile_program",
        kiln_rt_compile_program as *const u8,
    );
    builder.symbol(
        "kiln_rt_encode_packet",
        crate::packet_heap::kiln_rt_encode_packet as *const u8,
    );
    builder.symbol(
        "kiln_rt_write_packet",
        crate::packet_heap::kiln_rt_write_packet as *const u8,
    );
    builder.symbol_lookup_fn(Box::new(|name| {
        kiln_rt::exported(name).map(|a| a as *const u8)
    }));
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
    // The records point into `out`'s site bytes, which `Loaded` keeps;
    // code::register copies them.
    let debug: Vec<kiln_rt::debug::FuncDebugRecord> = out
        .debug
        .iter()
        .map(|d| {
            let data = |id, addend: i64| (module.get_finalized_data(id).0 as i64 + addend) as u64;
            let (info, flags) = match d.info {
                None => (0, 0),
                Some(DebugInfo::Word(n)) => (n as u64, 0),
                Some(DebugInfo::Data(id, addend)) => (data(id, addend), 0),
                Some(DebugInfo::Indirect(id, off)) => {
                    (data(id, off), kiln_rt::debug::FLAG_INDIRECT)
                }
            };
            kiln_rt::debug::FuncDebugRecord {
                start: module.get_finalized_function(d.func) as usize,
                len: d.len as u64,
                info,
                flags,
                sites: d.sites.as_ptr(),
                nsites: d.sites.len() as u64,
            }
        })
        .collect();
    match memory {
        Memory::Own(_) => kiln_rt::register_code(&callsites, &maps, &roots, &debug),
        Memory::Shared => kiln_rt::code::register(&callsites, &maps, &roots, &debug),
    }
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
const LITERALS_NAME: &str = crate::lir::cells::LITERALS;

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
    let t = std::time::Instant::now();
    let src = unsafe { kiln_rt::object::string_value(text) };
    let s = crate::sexp::parse_one(&src).map_err(|e| e.to_string())?;
    let kir = kir::parse_module(&s)?;
    unsafe { install_module(&kir, literals, Some(src.len()), t) }
}

/// Compile an indexed packet from a simple vector of octets. This entry
/// copies the request before decoding and never calls a Lisp safepoint.
/// The caller's Lisp frame roots the literal vector until its elements
/// have been installed into registered static root slots.
///
/// # Safety
/// `packet` and `literals` must be valid Lisp objects. The current runtime
/// has one mutator; no Lisp GC or callback may run during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_compile_packet(
    _ctx: *mut Context,
    packet: u64,
    literals: u64,
) -> u64 {
    let result = unsafe { compile_packet(packet, literals) };
    match result {
        Ok(init) => init,
        Err(error) => {
            eprintln!("kiln_rt_compile_packet: {error}");
            kiln_rt::object::nil()
        }
    }
}

unsafe fn compile_packet(packet: u64, literals: u64) -> Result<u64, String> {
    use kiln_rt::object::{
        KIND_MASK, KIND_SIMPLE_VECTOR, fixnum_value, header, header_length, is_fixnum, is_general,
        untag,
    };
    let t = std::time::Instant::now();
    if !is_general(packet) || unsafe { header(packet) } & KIND_MASK != KIND_SIMPLE_VECTOR {
        return Err("request must be a simple vector of octets".into());
    }
    if !is_general(literals) || unsafe { header(literals) } & KIND_MASK != KIND_SIMPLE_VECTOR {
        return Err("literals must be a simple vector".into());
    }
    let n = header_length(unsafe { header(packet) });
    if n > crate::packet::schema::MAX_BYTES as usize {
        return Err("request too large".into());
    }
    let words = unsafe { std::slice::from_raw_parts((untag(packet) + 8) as *const u64, n) };
    let bytes = words
        .iter()
        .map(|&word| {
            if !is_fixnum(word) {
                return Err("request contains a non-octet".to_string());
            }
            u8::try_from(fixnum_value(word)).map_err(|_| "request contains a non-octet".to_string())
        })
        .collect::<Result<Vec<_>, _>>()?;
    let kir = crate::packet::load(&bytes)?;
    unsafe { install_module(&kir, literals, Some(bytes.len()), t) }
}

/// Direct image adapter for the same backend program schema used in packets.
/// It snapshots records once rather than round-tripping through a Lisp byte vector.
///
/// # Safety
/// Arguments must be valid Lisp values. Like the packet compiler, this
/// entry assumes one mutator and performs no Lisp safepoint or callback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_compile_program(
    _ctx: *mut Context,
    program: u64,
    literals: u64,
    target: u64,
) -> u64 {
    use kiln_rt::object::*;
    let result = (|| {
        let t = std::time::Instant::now();
        let target = if is_fixnum(target) {
            u64::try_from(fixnum_value(target)).map_err(|_| "invalid target fingerprint")?
        } else if is_general(target) && unsafe { header(target) } & KIND_MASK == KIND_BIGNUM {
            u64::try_from(unsafe { kiln_rt::bignum::to_bigint(target) })
                .map_err(|_| "invalid target fingerprint")?
        } else {
            return Err("invalid target fingerprint".to_string());
        };
        if target != crate::packet::target_fingerprint() {
            return Err("target ABI fingerprint mismatch".into());
        }
        if !is_general(literals) || unsafe { header(literals) } & KIND_MASK != KIND_SIMPLE_VECTOR {
            return Err("literals must be a simple vector".into());
        }
        let program = unsafe { crate::packet_heap::snapshot_program(program) }?;
        let kir = crate::packet::compile_program(&program)?;
        unsafe { install_module(&kir, literals, None, t) }
    })();
    match result {
        Ok(init) => init,
        Err(error) => {
            eprintln!("kiln_rt_compile_program: {error}");
            nil()
        }
    }
}

unsafe fn install_module(
    kir: &kir::Module,
    literals: u64,
    input_size: Option<usize>,
    t: std::time::Instant,
) -> Result<u64, String> {
    use kiln_rt::object::{header, header_length, untag};
    let n = header_length(unsafe { header(literals) });
    if kir.inits.len() != 1 {
        return Err("image compilation requires exactly one init function".into());
    }
    // Validate the literal table before code or roots are registered.
    if let Some(data) = kir.data.iter().find(|d| d.name == LITERALS_NAME) {
        if !matches!(&data.contents, kir::DataContents::Words(words) if words.len() == n) {
            return Err("literal vector does not match the module's literal words".into());
        }
        let roots: std::collections::HashSet<_> = kir
            .roots
            .iter()
            .filter(|(name, _)| name == LITERALS_NAME)
            .map(|(_, index)| *index as usize)
            .collect();
        if (0..n).any(|index| !roots.contains(&index)) {
            return Err("literal word has no static root".into());
        }
    } else if n != 0 {
        return Err("missing literal words".into());
    }
    let patch_data: std::collections::HashMap<_,_> = kir.data.iter().map(|d| (d.name.as_str(),d)).collect();
    let patch_roots: std::collections::HashSet<_> = kir.roots.iter().cloned().collect();
    for (name, word, literal) in &kir.literal_patches {
        let data = patch_data.get(name.as_str()).ok_or("literal patch has no data")?;
        if *literal >= n || !matches!(&data.contents, kir::DataContents::Words(words) if (*word as usize) < words.len()) {
            return Err("literal patch out of range".into());
        }
        if !patch_roots.contains(&(name.clone(), *word)) {
            return Err("literal patch has no static root".into());
        }
    }
    let loaded = load(kir, &Options { dump_clif: false }, Memory::Shared)?;
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
    for (name, word, literal) in &kir.literal_patches {
        let id = loaded.out.data.get(name).ok_or("missing literal patch data")?;
        let (words, _) = loaded.module.get_finalized_data(*id);
        let elements = (untag(literals) + 8) as *const u64;
        unsafe { *(words as *mut u64).add(*word as usize) = *elements.add(*literal) };
    }
    let inits = loaded.inits();
    if std::env::var("KILN_TIME").is_ok() {
        let source = input_size.map_or_else(
            || "structured program".to_string(),
            |n| format!("{n} bytes"),
        );
        eprintln!("kiln compiler: {source} in {:?}", t.elapsed());
    }
    if std::env::var("KILN_PERF_MAP").is_ok() {
        append_perf_map(&loaded.module);
    }
    // The memory stays: the code is part of the image now.
    std::mem::forget(loaded);
    inits
        .first()
        .copied()
        .ok_or_else(|| "no init function".into())
}

/// Lines of perf's map (/tmp/perf-PID.map) for the functions of `module`:
/// "START SIZE NAME" in hex. A function's size is up to the next one.
pub fn perf_map_lines(module: &JITModule) -> String {
    use cranelift_module::Module;
    let mut funcs: Vec<(usize, String)> = module
        .declarations()
        .get_functions()
        .filter(|(_, d)| d.linkage.is_definable())
        .map(|(id, d)| {
            (
                module.get_finalized_function(id) as usize,
                d.linkage_name(id).into_owned(),
            )
        })
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
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
    {
        let _ = f.write_all(perf_map_lines(module).as_bytes());
    }
}
