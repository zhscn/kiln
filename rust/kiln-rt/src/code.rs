//! The region for code compiled into the running image (COMPILE,
//! docs/11 §11), at a fixed address so that heap images can hold it
//! (docs/15 §6): kiln-cg's JIT allocates its code and data here, in
//! pages handed out in increasing order, and registers each module's
//! tables through `register`, which keeps a copy for images.

use crate::gc::StackMapRecord;
use crate::unwind::CallSiteRecord;
use std::sync::Mutex;

/// Above the image region (image.rs), below the addresses the kernel
/// hands out to mmap.
pub const CODE_BASE: usize = 0x3800_0000_0000;
pub const CODE_SIZE: usize = 16 << 30;
pub const PAGE: usize = 4096;

/// Protection of a segment once its module is finalized.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u64)]
pub enum Prot {
    ReadWrite = 0,
    ReadOnly = 1,
    ReadExecute = 2,
}

#[derive(Clone, Copy, Debug)]
pub struct Segment {
    pub addr: usize,
    pub len: usize,
    pub prot: Prot,
}

/// The tables of a module compiled into the image, as registered.
#[derive(Clone, Default)]
pub struct Tables {
    pub callsites: Vec<CallSiteRecord>,
    /// (function, return offset, offsets)
    pub maps: Vec<(usize, u32, Vec<u32>)>,
    pub roots: Vec<usize>,
    /// Debug records without their call sites, which follow: the
    /// records' `sites` point into them once registered.
    pub debug: Vec<(crate::debug::FuncDebugRecord, Vec<u8>)>,
}

pub struct Region {
    /// End of the pages handed out.
    pub top: usize,
    pub segments: Vec<Segment>,
    pub tables: Vec<Tables>,
}

pub static REGION: Mutex<Region> =
    Mutex::new(Region { top: CODE_BASE, segments: Vec::new(), tables: Vec::new() });

fn reserve() -> Result<(), String> {
    static RESERVED: std::sync::OnceLock<Result<(), String>> = std::sync::OnceLock::new();
    RESERVED
        .get_or_init(|| {
            let p = unsafe {
                libc::mmap(
                    CODE_BASE as *mut libc::c_void,
                    CODE_SIZE,
                    libc::PROT_NONE,
                    libc::MAP_PRIVATE | libc::MAP_ANONYMOUS | libc::MAP_NORESERVE | libc::MAP_FIXED_NOREPLACE,
                    -1,
                    0,
                )
            };
            if p as usize == CODE_BASE {
                Ok(())
            } else {
                Err(format!(
                    "cannot reserve the code region at {CODE_BASE:#x}: {}",
                    std::io::Error::last_os_error()
                ))
            }
        })
        .clone()
}

/// Hands out `len` bytes (a multiple of the page size) of readable and
/// writable pages, above all pages handed out before.
pub fn allocate_pages(len: usize) -> Result<usize, String> {
    reserve()?;
    let mut r = REGION.lock().unwrap();
    let addr = r.top;
    if addr + len > CODE_BASE + CODE_SIZE {
        return Err("the code region is full".into());
    }
    protect(addr, len, Prot::ReadWrite)?;
    r.top += len;
    Ok(addr)
}

pub fn protect(addr: usize, len: usize, prot: Prot) -> Result<(), String> {
    let p = match prot {
        Prot::ReadWrite => libc::PROT_READ | libc::PROT_WRITE,
        Prot::ReadOnly => libc::PROT_READ,
        Prot::ReadExecute => libc::PROT_READ | libc::PROT_EXEC,
    };
    if unsafe { libc::mprotect(addr as *mut libc::c_void, len, p) } != 0 {
        return Err(format!("mprotect: {}", std::io::Error::last_os_error()));
    }
    Ok(())
}

/// Records a finalized segment, with its protection applied.
pub fn add_segment(addr: usize, len: usize, prot: Prot) -> Result<(), String> {
    protect(addr, len, prot)?;
    REGION.lock().unwrap().segments.push(Segment { addr, len, prot });
    Ok(())
}

/// Is `addr` in the pages handed out?
pub fn contains(addr: usize) -> bool {
    addr >= CODE_BASE && addr < REGION.lock().unwrap().top
}

/// Registers the call sites, stack maps and static roots of a module
/// compiled into the region, and keeps them for images.
pub fn register(
    callsites: &[CallSiteRecord],
    maps: &[StackMapRecord],
    roots: &[usize],
    debug: &[crate::debug::FuncDebugRecord],
) {
    let tables = Tables {
        callsites: callsites.to_vec(),
        maps: maps
            .iter()
            .map(|m| (m.func, m.ret_off, unsafe { std::slice::from_raw_parts(m.offsets, m.count as usize) }.to_vec()))
            .collect(),
        roots: roots.to_vec(),
        debug: debug
            .iter()
            .map(|r| (*r, unsafe { std::slice::from_raw_parts(r.sites, r.nsites as usize) }.to_vec()))
            .collect(),
    };
    register_tables(&tables);
    REGION.lock().unwrap().tables.push(tables);
}

fn register_tables(t: &Tables) {
    let maps: Vec<StackMapRecord> = t
        .maps
        .iter()
        .map(|(func, ret_off, offsets)| StackMapRecord {
            func: *func,
            ret_off: *ret_off,
            count: offsets.len() as u32,
            offsets: offsets.as_ptr(),
        })
        .collect();
    crate::unwind::register_callsites(&t.callsites);
    crate::gc::register_stack_maps(&maps);
    crate::gc::register_static_roots(&t.roots);
    // The site bytes stay where they are: tables are never dropped.
    let debug: Vec<crate::debug::FuncDebugRecord> = t
        .debug
        .iter()
        .map(|(r, sites)| crate::debug::FuncDebugRecord { sites: sites.as_ptr(), nsites: sites.len() as u64, ..*r })
        .collect();
    crate::debug::register(&debug);
}

/// Restores the region from an image: `bytes` are the contents of the
/// pages from CODE_BASE up, which become `segments`; `tables` are
/// registered again.
pub fn restore(bytes_at: impl FnOnce(usize, usize) -> Result<(), String>, top: usize,
               segments: Vec<Segment>, tables: Vec<Tables>) -> Result<(), String> {
    reserve()?;
    let len = top - CODE_BASE;
    if len > 0 {
        protect(CODE_BASE, len, Prot::ReadWrite)?;
        bytes_at(CODE_BASE, len)?;
    }
    for s in &segments {
        protect(s.addr, s.len, s.prot)?;
    }
    for t in &tables {
        register_tables(t);
    }
    let mut r = REGION.lock().unwrap();
    r.top = top;
    r.segments = segments;
    r.tables = tables;
    Ok(())
}
