//! Debug information of compiled code and the inspection of Lisp frames
//! (docs/17).
//!
//! kiln-cg emits one record per function: its code range, its debug info
//! object (a Lisp object that lower.lisp built: name, source file,
//! variable names) and its call sites. A call site has the source range
//! of the call and the variables whose values are in stack slots during
//! the call, as offsets from the SP at the call, which is the callee's
//! frame pointer plus 16 (as for the stack maps, gc.rs).
//!
//! Lisp walks its stack through `kiln_rt_frame`. A frame is named by a
//! handle: the frame pointer of the frame it called, whose return address
//! is in the frame's function. Handles are aligned addresses, so they are
//! fixnums to Lisp.

use crate::context::Context;
use crate::object;
use std::sync::RwLock;

/// Layout is part of the ABI (kiln-cg's `emit_module_info`).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct FuncDebugRecord {
    pub start: usize,
    pub len: u64,
    /// The debug info object; with bit 0 of `flags`, the address of a
    /// word holding it. 0: none.
    pub info: u64,
    pub flags: u64,
    /// The call sites, encoded (kiln-cg's `encode_debug_sites`).
    pub sites: *const u8,
    pub nsites: u64,
}

unsafe impl Send for FuncDebugRecord {}
unsafe impl Sync for FuncDebugRecord {}

pub const FLAG_INDIRECT: u64 = 1;

struct Table {
    records: Vec<FuncDebugRecord>,
    sorted: bool,
}

static TABLE: RwLock<Table> = RwLock::new(Table { records: Vec::new(), sorted: true });

/// Registers the records of loaded code. The call sites they point to
/// must stay. Sorting waits for the first lookup: startup does not pay.
pub fn register(records: &[FuncDebugRecord]) {
    if records.is_empty() {
        return;
    }
    let mut t = TABLE.write().unwrap();
    t.records.extend_from_slice(records);
    t.sorted = false;
}

/// `KILN_FUNCTION_MAP=PATH`: writes each function's start address (hex)
/// and printed name, one per line, for naming the functions of AOT code in
/// external profilers (perf reports them by their KIR labels).
pub fn write_function_map() {
    let Ok(path) = std::env::var("KILN_FUNCTION_MAP") else { return };
    let t = TABLE.read().unwrap();
    let mut out = String::new();
    for r in &t.records {
        let info = info_object(r);
        let mut name = String::new();
        if info != object::nil() {
            unsafe { object::write_object(&mut name, *((object::untag(info) + 8) as *const u64)) };
        }
        out.push_str(&format!("{:x} {}\n", r.start, name.replace('\n', " ")));
    }
    let _ = std::fs::write(path, out);
}

/// The record of the function whose code holds the return address `ret`.
pub fn lookup(ret: usize) -> Option<FuncDebugRecord> {
    if !TABLE.read().unwrap().sorted {
        let mut t = TABLE.write().unwrap();
        if !t.sorted {
            t.records.sort_by_key(|r| r.start);
            t.sorted = true;
        }
    }
    let t = TABLE.read().unwrap();
    let i = t.records.partition_point(|r| r.start < ret);
    let r = *t.records.get(i.checked_sub(1)?)?;
    (ret <= r.start + r.len as usize).then_some(r)
}

/// A call site: its source range and its variables (name index, offset
/// from the SP in words).
pub struct Site {
    pub loc: Option<(u64, u64)>,
    pub vars: Vec<(u64, u64)>,
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl Reader<'_> {
    fn varint(&mut self) -> Option<u64> {
        let mut n = 0u64;
        let mut shift = 0;
        loop {
            let b = *self.bytes.get(self.pos)?;
            self.pos += 1;
            n |= u64::from(b & 0x7f) << shift;
            if b & 0x80 == 0 {
                return Some(n);
            }
            shift += 7;
        }
    }
}

/// The call site of `r` at the return offset `ret_off`, if it has one.
pub fn site(r: &FuncDebugRecord, ret_off: u64) -> Option<Site> {
    let bytes = unsafe { std::slice::from_raw_parts(r.sites, r.nsites as usize) };
    let mut rd = Reader { bytes, pos: 0 };
    while rd.pos < bytes.len() {
        let off = rd.varint()?;
        let start = rd.varint()?;
        let loc = if start == 0 { None } else { Some((start - 1, rd.varint()?)) };
        let n = rd.varint()?;
        let mut vars = Vec::with_capacity(n as usize);
        for _ in 0..n {
            vars.push((rd.varint()?, rd.varint()?));
        }
        if off == ret_off {
            return Some(Site { loc, vars });
        }
        if off > ret_off {
            return None;
        }
    }
    None
}

/// The debug info object of `r`, or NIL.
pub fn info_object(r: &FuncDebugRecord) -> u64 {
    match r.info {
        0 => object::nil(),
        w if r.flags & FLAG_INDIRECT != 0 => unsafe { *(w as *const u64) },
        w => w,
    }
}

fn fixnum(n: u64) -> u64 {
    n << 1
}

pub const FRAME_LIST: u64 = 0;
pub const FRAME_INFO: u64 = 1;
pub const FRAME_LOC_START: u64 = 2;
pub const FRAME_LOC_END: u64 = 3;
pub const FRAME_NVARS: u64 = 4;
pub const FRAME_VAR_NAME: u64 = 5;
pub const FRAME_VAR_VALUE: u64 = 6;
pub const FRAME_PC: u64 = 7;
pub const FRAME_OFFSET: u64 = 8;

/// Frame inspection for Lisp; `op` is a fixnum, the other arguments and
/// the result Lisp values:
///
/// - FRAME_LIST, `a` a frame pointer (`(fp)` of a Lisp function), `b` a
///   simple vector: stores the handles of the Lisp frames older than the
///   one of `a`, innermost first, as many as fit; returns their number.
/// - FRAME_INFO, `a` a handle: the function's debug info object or NIL.
/// - FRAME_LOC_START, FRAME_LOC_END: the call's source range or NIL.
/// - FRAME_NVARS; FRAME_VAR_NAME and FRAME_VAR_VALUE with `b` an index:
///   the variables at the call, the index of the name in the debug info.
/// - FRAME_PC: the return address; FRAME_OFFSET: from the function's start.
///
/// Nothing allocates here.
///
/// # Safety
/// Handles must come from FRAME_LIST, for frames still on the stack.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_frame(ctx: *mut Context, op: u64, a: u64, b: u64) -> u64 {
    let nil = object::nil();
    let op = op >> 1;
    if op == FRAME_LIST {
        return fixnum(unsafe { list_frames(&*ctx, a as usize, b) });
    }
    if op >= crate::profile::PROFILE_START {
        return crate::profile::op(ctx, op, a, b);
    }
    let h = a as usize;
    let ret = unsafe { *((h + 8) as *const usize) };
    let Some(r) = lookup(ret) else { return nil };
    let ret_off = (ret - r.start) as u64;
    match op {
        FRAME_INFO => info_object(&r),
        FRAME_PC => fixnum(ret as u64),
        FRAME_OFFSET => fixnum(ret_off),
        _ => {
            let site = site(&r, ret_off);
            let var = |i: u64| site.as_ref().and_then(|s| s.vars.get(i as usize).copied());
            match (op, &site) {
                (FRAME_LOC_START, Some(Site { loc: Some((s, _)), .. })) => fixnum(*s),
                (FRAME_LOC_END, Some(Site { loc: Some((_, e)), .. })) => fixnum(*e),
                (FRAME_NVARS, _) => fixnum(site.as_ref().map_or(0, |s| s.vars.len() as u64)),
                (FRAME_VAR_NAME, _) => var(b >> 1).map_or(nil, |(n, _)| fixnum(n)),
                (FRAME_VAR_VALUE, _) => var(b >> 1)
                    .map_or(nil, |(_, off)| unsafe { *((h + 16 + off as usize * 8) as *const u64) }),
                _ => nil,
            }
        }
    }
}

/// See FRAME_LIST. Walks the frame pointers of the current segment of
/// Lisp frames, then of the suspended ones (stack.rs).
unsafe fn list_frames(ctx: &Context, start: usize, vector: u64) -> u64 {
    let cap = object::header_length(unsafe { object::header(vector) });
    let elements = (object::untag(vector) + 8) as *mut u64;
    let mut n = 0;
    let mut fp = start;
    let mut base = ctx.stack_base_fp;
    let mut seg = ctx.segments;
    loop {
        while fp != base && fp != 0 {
            let ret = unsafe { *((fp + 8) as *const usize) };
            if lookup(ret).is_some() {
                if (n as usize) < cap {
                    unsafe { *elements.add(n as usize) = fp as u64 };
                }
                n += 1;
            }
            fp = unsafe { *(fp as *const usize) };
        }
        if seg.is_null() {
            return n;
        }
        unsafe {
            fp = (*seg).top_fp;
            base = (*seg).base_fp;
            seg = (*seg).prev;
        }
    }
}
