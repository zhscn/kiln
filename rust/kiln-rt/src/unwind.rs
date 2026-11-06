//! Non-local exit (constraint C3).
//!
//! Compiled code establishes `DynEntry` records in its own frame and calls
//! other code with Cranelift `try_call` while those records are live. Every
//! such call site has one handler. To transfer control into a frame, the
//! runtime finds that frame's active call site by walking the frame-pointer
//! chain, looks the return address up in the call-site table, and resumes at
//! the handler with payload (entry, value) in the exception registers.
//!
//! Lisp functions use Cranelift's `tail` convention, which treats every
//! register as clobbered on the exceptional edge, so no callee-saved register
//! needs restoring: setting PC, SP and FP is enough.

use crate::context::{
    Context, DYN_BIND, DYN_CATCH, DYN_PROGV, DYN_CLEANUP_RUNNING, DYN_EXIT_POINT, DYN_STACK_BOUNDARY, DYN_UNWIND_PROTECT,
    DynEntry,
};
use std::sync::RwLock;

/// One call site with an exception handler, in absolute addresses.
#[derive(Clone, Copy, Debug)]
pub struct CallSite {
    pub ret_addr: usize,
    pub handler: usize,
    pub frame_offset: u32,
}

/// Call-site record as emitted by kiln-cg into object files. Layout is part
/// of the ABI.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CallSiteRecord {
    pub func: usize,
    pub ret_off: u32,
    pub handler_off: u32,
    pub frame_offset: u32,
    pub _pad: u32,
}

static CALLSITES: RwLock<Vec<CallSite>> = RwLock::new(Vec::new());

pub fn register_callsites(records: &[CallSiteRecord]) {
    let mut new: Vec<CallSite> = records
        .iter()
        .map(|r| CallSite {
            ret_addr: r.func + r.ret_off as usize,
            handler: r.func + r.handler_off as usize,
            frame_offset: r.frame_offset,
        })
        .collect();
    new.sort_by_key(|c| c.ret_addr);
    let mut table = CALLSITES.write().unwrap();
    // Code loaded later (compiled at run time) usually lies above: then
    // the table stays sorted without sorting it again.
    let append = match (table.last(), new.first()) {
        (Some(last), Some(first)) => last.ret_addr < first.ret_addr,
        _ => true,
    };
    table.extend(new);
    if !append {
        table.sort_by_key(|c| c.ret_addr);
    }
}

fn lookup_callsite(ret_addr: usize) -> Option<CallSite> {
    let table = CALLSITES.read().unwrap();
    table
        .binary_search_by_key(&ret_addr, |c| c.ret_addr)
        .ok()
        .map(|i| table[i])
}

fn fatal(msg: &str) -> ! {
    eprintln!("kiln: fatal: {msg}");
    std::process::abort()
}

#[cfg(target_arch = "x86_64")]
unsafe fn resume_to_handler(pc: usize, sp: usize, fp: usize, p0: u64, p1: u64) -> ! {
    unsafe {
        core::arch::asm!(
            "mov rsp, rcx",
            "mov rbp, rsi",
            "jmp rdi",
            in("rax") p0,
            in("rdx") p1,
            in("rcx") sp,
            in("rsi") fp,
            in("rdi") pc,
            options(nostack, nomem, noreturn),
        );
    }
}

/// Resume in the frame whose frame pointer is `frame_fp`, at the handler of
/// its active call site. `start_fp` is the frame pointer of the trampoline
/// through which compiled code entered the runtime; it is younger than
/// `frame_fp` on the same stack.
unsafe fn resume_in_frame(start_fp: usize, frame_fp: usize, p0: u64, p1: u64) -> ! {
    let mut fp = start_fp;
    loop {
        if fp == 0 {
            fatal("unwind target frame not found on the stack");
        }
        let caller_fp = unsafe { *(fp as *const usize) };
        if caller_fp == frame_fp {
            let ret_addr = unsafe { *((fp + 8) as *const usize) };
            let Some(cs) = lookup_callsite(ret_addr) else {
                fatal(&format!(
                    "no handler for call site {ret_addr:#x} in target frame"
                ));
            };
            let sp = frame_fp - cs.frame_offset as usize;
            unsafe { resume_to_handler(cs.handler, sp, frame_fp, p0, p1) }
        }
        fp = caller_fp;
    }
}

/// Unwind to `target`, running intervening cleanups. A cleanup runs with
/// its entry still linked (marked DYN_CLEANUP_RUNNING, holding the pending
/// target and value, which the GC updates) and ends by calling
/// `kiln_rt_continue_unwind`.
///
/// `packed` (0 or 1) says that `value` is a list of multiple values. It
/// travels in bit 0 of the target address (entries are 8-byte aligned):
/// in the payload register exn0 on arrival, and in `pend_target` while a
/// cleanup runs. Compiled code masks it off before comparing entries.
unsafe fn unwind_to(
    ctx: *mut Context,
    target: *mut DynEntry,
    value: u64,
    packed: u64,
    start_fp: usize,
) -> ! {
    let mut start_fp = start_fp;
    unsafe {
        loop {
            let top = (*ctx).dynenv;
            if top.is_null() {
                fatal("unwind target is not in the dynamic environment");
            }
            if top == target {
                (*ctx).dynenv = (*top).prev;
                resume_in_frame(start_fp, (*top).fp, top as u64 | packed, value);
            }
            if (*top).kind == DYN_UNWIND_PROTECT {
                (*top).kind = DYN_CLEANUP_RUNNING;
                (*top).pend_target = (target as u64 | packed) as *mut DynEntry;
                (*top).pend_value = value;
                resume_in_frame(start_fp, (*top).fp, top as u64, 0);
            }
            if (*top).kind == DYN_BIND {
                crate::special::unbind(ctx, top);
            }
            if (*top).kind == DYN_PROGV {
                crate::special::unbind_progv(ctx, top);
            }
            if (*top).kind == DYN_STACK_BOUNDARY {
                // Leave the current stack; continue on the one below.
                start_fp = crate::stack::leave_stack(ctx, top);
            }
            // A catch, a binding, a cleanup abandoned by this unwind, or a
            // boundary.
            (*ctx).dynenv = (*top).prev;
        }
    }
}

/// `(throw tag value)`. Called through a trampoline; `fp` is its frame pointer.
///
/// # Safety
/// Must be called by compiled code with a valid context.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_throw(
    ctx: *mut Context,
    tag: u64,
    value: u64,
    packed: u64,
    fp: usize,
) -> ! {
    unsafe {
        let mut e = (*ctx).dynenv;
        while !e.is_null() {
            if (*e).kind == DYN_CATCH && (*e).tag == tag {
                unwind_to(ctx, e, value, packed, fp);
            }
            e = (*e).prev;
        }
        let mut s = String::new();
        crate::object::write_object(&mut s, tag);
        crate::rtfun::error_exit(&format!("attempt to throw to a nonexistent tag: {s}"));
    }
}

/// Non-local `return-from` or `go`: unwind to the block or tagbody whose
/// exit-point entry has the tag `token` (a fresh heap object per
/// activation, taken from a closure; heap objects never hold stack
/// addresses, C5), passing `value` (the block's value, or the tag index).
/// Called through a trampoline; `fp` is its frame pointer.
///
/// # Safety
/// Must be called by compiled code with a valid context.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_exit_to(
    ctx: *mut Context,
    token: u64,
    value: u64,
    packed: u64,
    fp: usize,
) -> ! {
    unsafe {
        let mut e = (*ctx).dynenv;
        while !e.is_null() {
            if (*e).kind == DYN_EXIT_POINT && (*e).tag == token {
                unwind_to(ctx, e, value, packed, fp);
            }
            e = (*e).prev;
        }
        crate::rtfun::error_exit("attempt to exit to a block or tagbody that is no longer active");
    }
}

/// Called at the end of an unwind-protect cleanup that was entered by an unwind.
///
/// # Safety
/// Must be called by compiled code with a valid context and entry.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_continue_unwind(
    ctx: *mut Context,
    entry: *mut DynEntry,
    fp: usize,
) -> ! {
    unsafe {
        if (*ctx).dynenv != entry {
            fatal("continue_unwind: cleanup entry is not innermost");
        }
        (*ctx).dynenv = (*entry).prev;
        let target = (*entry).pend_target as u64;
        unwind_to(ctx, (target & !1) as *mut DynEntry, (*entry).pend_value, target & 1, fp)
    }
}
