//! Heap images (docs/15-heap-image.md).
//!
//! `kiln_rt_save_image` writes the objects reachable from the static
//! roots (and a toplevel function) into a file, laid out as they will be
//! mapped at `IMAGE_BASE`, together with the values of the static roots.
//! An AOT executable started with an image (`KILN_IMAGE`, or one appended
//! to the executable) maps it there and calls the toplevel function
//! instead of running the modules' init functions.
//!
//! The image region is outside MMTk's spaces: its objects never move and
//! are never freed. They may come to point into the heap, so every
//! collection scans the region for such slots (there is no write barrier
//! yet, docs/15 §4).
//!
//! An image is only valid for the executable that wrote it: code and
//! static data are at fixed addresses (the executables are not
//! position-independent), and a fingerprint of the static roots checks it.

use crate::context::Context;
use crate::object::{
    self, KIND_FUNCALLABLE_INSTANCE, KIND_FUNCTION, KIND_MASK, TAG_MASK,
    is_pointer, object_bytes, untag,
};
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom, Write};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

/// Where an image's objects are mapped: above MMTk's heap range
/// (0x0200_0000_0000..0x2200_0000_0000) and below the addresses the
/// kernel hands out to mmap.
pub const IMAGE_BASE: usize = 0x3000_0000_0000;
const PAGE: usize = 4096;
const MAGIC: [u8; 8] = *b"KILNIMG1";
/// Last 16 bytes of an executable with an image appended: the file offset
/// of the image, then this.
const TRAILER_MAGIC: [u8; 8] = *b"KILNEXE1";

/// End of the mapped image region (IMAGE_BASE if there is none).
static IMAGE_END: AtomicUsize = AtomicUsize::new(IMAGE_BASE);
/// Set when kiln-cg's JIT loads a program (not into the code region,
/// code.rs): images cannot hold its code.
static RUNTIME_CODE: AtomicBool = AtomicBool::new(false);
static MODULE_INFO: AtomicUsize = AtomicUsize::new(0);
/// Fingerprint of the executable (see `fingerprint`), once its tables are
/// registered.
static FINGERPRINT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

pub(crate) fn note_runtime_code() {
    RUNTIME_CODE.store(true, Ordering::Relaxed);
}

pub(crate) fn note_module_info(info: usize) {
    MODULE_INFO.store(info, Ordering::Relaxed);
}

/// Called once the executable's static roots are registered, before any
/// code is compiled into the image.
pub(crate) fn note_executable() {
    FINGERPRINT.store(fingerprint(&crate::gc::static_roots()), Ordering::Relaxed);
}

/// Is ADDR in the mapped image region?
#[inline]
pub fn contains(addr: usize) -> bool {
    addr >= IMAGE_BASE && addr < IMAGE_END.load(Ordering::Relaxed)
}

/// The mapped image region, if any.
pub fn region() -> Option<(usize, usize)> {
    let end = IMAGE_END.load(Ordering::Relaxed);
    (end > IMAGE_BASE).then_some((IMAGE_BASE, end))
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Header {
    magic: [u8; 8],
    fingerprint: u64,
    base: u64,
    /// Bytes of objects, mapped at `base`; they follow the header page.
    bytes: u64,
    /// The function to call instead of the init functions (tagged).
    toplevel: u64,
    next_tls_index: u64,
    next_identity_hash: u64,
    /// (address, value) pairs of static words follow the objects (padded
    /// to a page).
    nstatic: u64,
    /// End of the code region's pages (code.rs); their contents follow
    /// the static words, then `code_words` words describing the segments
    /// and tables of the code region.
    code_top: u64,
    code_words: u64,
}

const HEADER_WORDS: usize = std::mem::size_of::<Header>() / 8;

/// Identifies the executable: the address of its module info and the
/// addresses of its static roots.
fn fingerprint(roots: &[usize]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut mix = |x: u64| {
        for b in x.to_le_bytes() {
            h ^= b as u64;
            h = h.wrapping_mul(0x100_0000_01b3);
        }
    };
    mix(MODULE_INFO.load(Ordering::Relaxed) as u64);
    mix(roots.len() as u64);
    for &r in roots {
        mix(r as u64);
    }
    h
}

/// (offset of the first Lisp field, number of Lisp fields) of an object
/// with header `h` (the GC scans the same fields).
pub fn lisp_fields(h: u64) -> (usize, usize) {
    use object::*;
    match h & KIND_MASK {
        KIND_CONS => (8, 2),
        KIND_SIMPLE_VECTOR => (8, header_length(h)),
        // Skip the entry address; the env words are Lisp values.
        KIND_FUNCTION => (16, header_length(h)),
        // name, package, function, value, TLS index (a fixnum), plist,
        // setf function
        KIND_SYMBOL => (8, 7),
        KIND_STRING | KIND_BIGNUM | KIND_DOUBLE => (8, 0),
        KIND_RATIO => (8, 2),
        KIND_INSTANCE => (8, 1),
        // Skip the entry address: rack and installed function.
        KIND_FUNCALLABLE_INSTANCE => (16, 2),
        KIND_RACK => (8, header_length(h)),
        k => panic!("unexpected object kind {k}"),
    }
}

unsafe extern "C" {
    static __executable_start: u8;
    static etext: u8;
}

fn in_text(addr: usize) -> bool {
    let start = &raw const __executable_start as usize;
    let end = &raw const etext as usize;
    (addr >= start && addr < end) || crate::code::contains(addr)
}

/// The code region's segments and tables as words.
fn code_words(r: &crate::code::Region) -> Vec<u64> {
    let mut w = vec![r.segments.len() as u64];
    for s in &r.segments {
        w.extend([s.addr as u64, s.len as u64, s.prot as u64]);
    }
    w.push(r.tables.len() as u64);
    for t in &r.tables {
        w.push(t.callsites.len() as u64);
        for c in &t.callsites {
            w.extend([c.func as u64, c.ret_off as u64 | (c.handler_off as u64) << 32, c.frame_offset as u64]);
        }
        w.push(t.maps.len() as u64);
        for (func, ret_off, offsets) in &t.maps {
            w.extend([*func as u64, *ret_off as u64, offsets.len() as u64]);
            w.extend(offsets.iter().map(|&o| o as u64));
        }
        w.push(t.roots.len() as u64);
        w.extend(t.roots.iter().map(|&r| r as u64));
        w.push(t.debug.len() as u64);
        for (r, sites) in &t.debug {
            w.extend([r.start as u64, r.len, r.info, r.flags, sites.len() as u64]);
            w.extend(sites.chunks(8).map(|c| {
                let mut b = [0u8; 8];
                b[..c.len()].copy_from_slice(c);
                u64::from_le_bytes(b)
            }));
        }
    }
    w
}

fn parse_code_words(w: &[u64]) -> (Vec<crate::code::Segment>, Vec<crate::code::Tables>) {
    use crate::code::{Prot, Segment, Tables};
    let mut i = 0;
    let mut next = || {
        i += 1;
        w[i - 1]
    };
    let segments = (0..next())
        .map(|_| Segment {
            addr: next() as usize,
            len: next() as usize,
            prot: match next() {
                0 => Prot::ReadWrite,
                1 => Prot::ReadOnly,
                _ => Prot::ReadExecute,
            },
        })
        .collect();
    let tables = (0..next())
        .map(|_| {
            let callsites = (0..next())
                .map(|_| {
                    let func = next() as usize;
                    let offs = next();
                    crate::unwind::CallSiteRecord {
                        func,
                        ret_off: offs as u32,
                        handler_off: (offs >> 32) as u32,
                        frame_offset: next() as u32,
                        _pad: 0,
                    }
                })
                .collect();
            let maps = (0..next())
                .map(|_| {
                    let func = next() as usize;
                    let ret_off = next() as u32;
                    let n = next();
                    (func, ret_off, (0..n).map(|_| next() as u32).collect())
                })
                .collect();
            let roots = (0..next()).map(|_| next() as usize).collect();
            let debug = (0..next())
                .map(|_| {
                    let r = crate::debug::FuncDebugRecord {
                        start: next() as usize,
                        len: next(),
                        info: next(),
                        flags: next(),
                        sites: std::ptr::null(),
                        nsites: 0,
                    };
                    let n = next() as usize;
                    let mut sites: Vec<u8> = (0..n.div_ceil(8)).flat_map(|_| next().to_le_bytes()).collect();
                    sites.truncate(n);
                    (r, sites)
                })
                .collect();
            Tables { callsites, maps, roots, debug }
        })
        .collect();
    (segments, tables)
}

// ---------------------------------------------------------------------------
// Saving

struct Saver {
    /// The image's objects, as words.
    out: Vec<u64>,
    /// Address of an object -> its word offset in `out`.
    copied: HashMap<usize, usize>,
}

impl Saver {
    /// Objects that go into the image: those in the heap or in the image
    /// this process started from. Static data stays where it is.
    fn movable(addr: usize) -> bool {
        crate::gc::in_heap(addr) || contains(addr)
    }

    /// `v` with its object, if movable, copied into the image.
    unsafe fn translate(&mut self, v: u64) -> u64 {
        if !is_pointer(v) || !Self::movable(untag(v)) {
            return v;
        }
        let addr = untag(v);
        let at = match self.copied.get(&addr) {
            Some(&at) => at,
            None => {
                let h = unsafe { *(addr as *const u64) };
                let words = object_bytes(h) / 8;
                let at = self.out.len();
                self.out
                    .extend_from_slice(unsafe { std::slice::from_raw_parts(addr as *const u64, words) });
                self.copied.insert(addr, at);
                at
            }
        };
        (IMAGE_BASE + 8 * at) as u64 | (v & TAG_MASK)
    }

    /// Translates the fields of the copied objects, copying the objects
    /// they point to in turn (Cheney's scan).
    unsafe fn scan(&mut self) -> Result<(), String> {
        let mut i = 0;
        while i < self.out.len() {
            let h = self.out[i];
            let kind = h & KIND_MASK;
            if kind == KIND_FUNCTION || kind == KIND_FUNCALLABLE_INSTANCE {
                let entry = self.out[i + 1] as usize;
                if !in_text(entry) {
                    return Err(format!(
                        "a function's code at {entry:#x} is not the executable's (code compiled at run time cannot be saved yet)"
                    ));
                }
            }
            let (first, n) = lisp_fields(h);
            for f in 0..n {
                let j = i + first / 8 + f;
                let v = self.out[j];
                self.out[j] = unsafe { self.translate(v) };
            }
            i += object_bytes(h) / 8;
        }
        Ok(())
    }
}

fn as_bytes(words: &[u64]) -> &[u8] {
    unsafe { std::slice::from_raw_parts(words.as_ptr() as *const u8, words.len() * 8) }
}

/// Writes an image to `path`: see the module documentation.
///
/// # Safety
/// Must be called on the Lisp thread, with no collection in progress;
/// `toplevel` must be a function.
pub unsafe fn save(path: &std::path::Path, toplevel: u64, executable: bool) -> Result<(), String> {
    if RUNTIME_CODE.load(Ordering::Relaxed) {
        return Err("only an AOT executable can save an image".into());
    }
    let roots = crate::gc::static_roots();
    let mut s = Saver { out: Vec::new(), copied: HashMap::new() };
    let mut statics = Vec::with_capacity(2 * roots.len());
    for &r in &roots {
        let v = unsafe { *(r as *const u64) };
        statics.push(r as u64);
        statics.push(unsafe { s.translate(v) });
    }
    let toplevel = unsafe { s.translate(toplevel) };
    unsafe { s.scan()? };
    let (code_top, code_tables) = {
        let r = crate::code::REGION.lock().unwrap();
        (r.top, code_words(&r))
    };
    let header = Header {
        magic: MAGIC,
        fingerprint: FINGERPRINT.load(Ordering::Relaxed),
        base: IMAGE_BASE as u64,
        bytes: (s.out.len() * 8) as u64,
        toplevel,
        next_tls_index: crate::special::tls_used() as u64,
        next_identity_hash: crate::rtfun::next_identity_hash(),
        nstatic: roots.len() as u64,
        code_top: code_top as u64,
        code_words: code_tables.len() as u64,
    };
    let mut page = vec![0u64; PAGE / 8];
    page[..HEADER_WORDS].copy_from_slice(unsafe {
        std::slice::from_raw_parts(&header as *const Header as *const u64, HEADER_WORDS)
    });
    s.out.resize((s.out.len() * 8).next_multiple_of(PAGE) / 8, 0);

    let err = |e: std::io::Error| format!("{}: {e}", path.display());
    // Write a new file and rename it: the executable writing the image
    // may be the file being replaced.
    let tmp = path.with_extension("kiln-tmp");
    let mut f = std::fs::File::create(&tmp).map_err(err)?;
    let mut start = 0u64;
    if executable {
        let mut exe = std::fs::File::open("/proc/self/exe").map_err(err)?;
        let mut bytes = Vec::new();
        exe.read_to_end(&mut bytes).map_err(err)?;
        // Leave out an image appended to this executable.
        if let Some(off) = trailer(&bytes) {
            bytes.truncate(off as usize);
        }
        bytes.resize(bytes.len().next_multiple_of(PAGE), 0);
        start = bytes.len() as u64;
        f.write_all(&bytes).map_err(err)?;
    }
    f.write_all(as_bytes(&page)).map_err(err)?;
    f.write_all(as_bytes(&s.out)).map_err(err)?;
    f.write_all(as_bytes(&statics)).map_err(err)?;
    f.write_all(unsafe {
        std::slice::from_raw_parts(crate::code::CODE_BASE as *const u8, code_top - crate::code::CODE_BASE)
    })
    .map_err(err)?;
    f.write_all(as_bytes(&code_tables)).map_err(err)?;
    if executable {
        f.write_all(&start.to_le_bytes()).map_err(err)?;
        f.write_all(&TRAILER_MAGIC).map_err(err)?;
        use std::os::unix::fs::PermissionsExt;
        f.set_permissions(std::fs::Permissions::from_mode(0o755)).map_err(err)?;
    }
    f.sync_all().map_err(err)?;
    drop(f);
    std::fs::rename(&tmp, path).map_err(err)?;
    Ok(())
}

/// The offset of the image appended to an executable whose last bytes
/// are `tail`, if any.
fn trailer(tail: &[u8]) -> Option<u64> {
    let n = tail.len();
    if n < 16 || tail[n - 8..] != TRAILER_MAGIC {
        return None;
    }
    Some(u64::from_le_bytes(tail[n - 16..n - 8].try_into().unwrap()))
}

/// `(%primop :save-image path toplevel executable)`: `path` a simple
/// vector of octets (UTF-8), `toplevel` a function, `executable` NIL or
/// not. Returns 0, or 1 after printing why the image could not be saved.
///
/// # Safety
/// Must be called by compiled code with valid arguments.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_save_image(_ctx: *mut Context, path: u64, toplevel: u64, executable: u64) -> u64 {
    use std::os::unix::ffi::OsStringExt;
    let path = std::path::PathBuf::from(std::ffi::OsString::from_vec(unsafe { crate::rtfun::vector_octets(path) }));
    match unsafe { save(&path, toplevel, executable != object::nil()) } {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("kiln: cannot save an image: {e}");
            2
        }
    }
}

// ---------------------------------------------------------------------------
// Loading

/// The image to start from: the file named by `KILN_IMAGE`, else one
/// appended to the executable. (file, offset of the image in it)
fn find() -> Result<Option<(std::fs::File, u64)>, String> {
    if let Some(path) = std::env::var_os("KILN_IMAGE").filter(|p| !p.is_empty()) {
        let f = std::fs::File::open(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        return Ok(Some((f, 0)));
    }
    let Ok(mut f) = std::fs::File::open("/proc/self/exe") else {
        return Ok(None);
    };
    let mut tail = [0u8; 16];
    if f.seek(SeekFrom::End(-16)).is_err() || f.read_exact(&mut tail).is_err() {
        return Ok(None);
    }
    Ok(trailer(&tail).map(|off| (f, off)))
}

/// Maps the image this process starts from, if any, and restores the
/// static words and the runtime's counters. Returns its toplevel
/// function. Called after the module's code is registered, before MMTk
/// is initialized (so that its reservations stay clear of the region).
pub fn load() -> Result<Option<u64>, String> {
    use std::os::unix::fs::FileExt;
    use std::os::unix::io::AsRawFd;
    let Some((f, start)) = find()? else {
        return Ok(None);
    };
    let err = |e: std::io::Error| format!("cannot read the image: {e}");
    let mut hw = [0u64; HEADER_WORDS];
    f.read_exact_at(unsafe { std::slice::from_raw_parts_mut(hw.as_mut_ptr() as *mut u8, HEADER_WORDS * 8) }, start)
        .map_err(err)?;
    let h: Header = unsafe { std::mem::transmute(hw) };
    if h.magic != MAGIC {
        return Err("not a kiln image".into());
    }
    if h.base as usize != IMAGE_BASE || h.fingerprint != FINGERPRINT.load(Ordering::Relaxed) {
        return Err("the image was saved by a different executable".into());
    }
    let bytes = h.bytes as usize;
    let mapped = bytes.next_multiple_of(PAGE);
    if bytes > 0 {
        let p = unsafe {
            libc::mmap(
                IMAGE_BASE as *mut libc::c_void,
                mapped,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_FIXED_NOREPLACE,
                f.as_raw_fd(),
                (start as usize + PAGE) as libc::off_t,
            )
        };
        if p as usize != IMAGE_BASE {
            return Err(format!("cannot map the image at {IMAGE_BASE:#x}: {}", std::io::Error::last_os_error()));
        }
    }
    let mut statics = vec![0u64; 2 * h.nstatic as usize];
    f.read_exact_at(
        unsafe { std::slice::from_raw_parts_mut(statics.as_mut_ptr() as *mut u8, statics.len() * 8) },
        start + (PAGE + mapped) as u64,
    )
    .map_err(err)?;
    // The code region, whose tables add static roots.
    let statics_end = start + (PAGE + mapped) as u64 + 16 * h.nstatic;
    let code_len = h.code_top as usize - crate::code::CODE_BASE;
    let mut cw = vec![0u64; h.code_words as usize];
    f.read_exact_at(
        unsafe { std::slice::from_raw_parts_mut(cw.as_mut_ptr() as *mut u8, cw.len() * 8) },
        statics_end + code_len as u64,
    )
    .map_err(err)?;
    let (segments, tables) = parse_code_words(&cw);
    crate::code::restore(
        |addr, len| {
            f.read_exact_at(unsafe { std::slice::from_raw_parts_mut(addr as *mut u8, len) }, statics_end)
                .map_err(err)
        },
        h.code_top as usize,
        segments,
        tables,
    )?;
    if crate::gc::static_roots().len() != h.nstatic as usize {
        return Err("the image's static roots are not the executable's".into());
    }
    for [addr, value] in statics.as_chunks::<2>().0 {
        unsafe { *(*addr as *mut u64) = *value };
    }
    crate::special::set_tls_used(h.next_tls_index);
    crate::rtfun::set_next_identity_hash(h.next_identity_hash);
    IMAGE_END.store(IMAGE_BASE + bytes, Ordering::Relaxed);
    Ok(Some(h.toplevel))
}

// ---------------------------------------------------------------------------
// Collection

/// Calls `f` with batches of the image's slots that point into the heap:
/// they are roots (the image's objects themselves are not traced).
pub fn heap_slots(mut f: impl FnMut(Vec<usize>)) {
    let Some((start, end)) = region() else { return };
    const BATCH: usize = 4096;
    let mut batch = Vec::with_capacity(BATCH);
    let mut a = start;
    while a < end {
        let h = unsafe { *(a as *const u64) };
        let (first, n) = lisp_fields(h);
        for i in 0..n {
            let slot = a + first + 8 * i;
            let v = unsafe { *(slot as *const u64) };
            if is_pointer(v) && crate::gc::in_heap(untag(v)) {
                batch.push(slot);
                if batch.len() == BATCH {
                    f(std::mem::replace(&mut batch, Vec::with_capacity(BATCH)));
                }
            }
        }
        a += object_bytes(h);
    }
    if !batch.is_empty() {
        f(batch);
    }
}
