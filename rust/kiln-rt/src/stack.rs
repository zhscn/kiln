//! Stacks and stack segments (constraints C2 and C8).
//!
//! A context's Lisp frames form segments: each segment runs from a top frame
//! (the trampoline through which Lisp entered the runtime) to a base frame
//! (a `kiln_enter` frame). The current segment's ends are in the context;
//! suspended segments are linked from `Context::segments`. The GC scans all
//! of them. Today a new segment starts when Lisp code runs on a fresh stack
//! through `%call-on-new-stack`; runtime callbacks into Lisp will use the
//! same mechanism.
//!
//! When `%call-on-new-stack` runs, a boundary entry is linked into the
//! dynamic environment. An unwind that reaches it leaves the new stack: it
//! restores the old segment and continues from the old stack's trampoline
//! frame.

use crate::context::{Context, DYN_STACK_BOUNDARY, DynEntry};
use std::sync::Mutex;

/// A suspended segment of Lisp frames.
#[repr(C)]
pub struct Segment {
    /// Frame pointer of the trampoline at the segment's top.
    pub top_fp: usize,
    /// Frame pointer of the `kiln_enter` frame at the segment's base.
    pub base_fp: usize,
    pub prev: *mut Segment,
    /// The stack limits of the stack below (see `set_stack_limits`).
    pub soft_limit: usize,
    pub hard_limit: usize,
}

/// Room below the soft limit for the handlers of a stack exhaustion; the
/// hard limit is this much above the stack's low end.
const HARD_RESERVE: usize = 64 << 10;

/// Sets the stack limits of `ctx` for a stack whose low end is `low` and
/// size `size`. Function entries below the soft limit signal a stack
/// exhaustion (STORAGE-CONDITION) and lower the limit to the hard one, so
/// that the handlers can run; below the hard limit the program ends. An
/// unwind that lands well above the soft limit raises the limit again.
pub fn set_stack_limits(ctx: *mut Context, low: usize, size: usize) {
    let soft_reserve = (size / 8).clamp(4 * HARD_RESERVE, 4 << 20);
    unsafe {
        (*ctx).stack_hard_limit = low + HARD_RESERVE;
        (*ctx).stack_soft_limit = low + soft_reserve;
        (*ctx).stack_limit = (*ctx).stack_soft_limit;
    }
}

/// Called by the poll slow path: true (once) when `fp` is below the stack
/// limit. Ends the program below the hard limit.
pub fn check_stack(ctx: *mut Context, fp: usize) -> bool {
    unsafe {
        if fp >= (*ctx).stack_limit {
            restore_stack_limit(ctx, fp);
            return false;
        }
        if (*ctx).stack_limit == (*ctx).stack_hard_limit {
            crate::rtfun::error_exit("control stack exhausted while handling a stack exhaustion");
        }
        (*ctx).stack_limit = (*ctx).stack_hard_limit;
        true
    }
}

/// Raises the stack limit back to the soft limit once the stack pointer
/// (`fp`) is well above it again.
pub fn restore_stack_limit(ctx: *mut Context, fp: usize) {
    unsafe {
        let soft = (*ctx).stack_soft_limit;
        if (*ctx).stack_limit != soft && fp > soft + (soft - (*ctx).stack_hard_limit) {
            (*ctx).stack_limit = soft;
        }
    }
}

pub const STACK_SIZE: usize = 1 << 20;
const GUARD_SIZE: usize = 1 << 12;

/// An mmap'ed stack with a guard page below it.
pub struct Stack {
    base: *mut u8,
    len: usize,
}

unsafe impl Send for Stack {}

impl Stack {
    pub fn new(size: usize) -> Stack {
        let len = size + GUARD_SIZE;
        unsafe {
            let base = libc::mmap(
                core::ptr::null_mut(),
                len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_PRIVATE | libc::MAP_ANONYMOUS | libc::MAP_NORESERVE,
                -1,
                0,
            );
            if base == libc::MAP_FAILED {
                crate::rtfun::error_exit("cannot allocate a stack");
            }
            libc::mprotect(base, GUARD_SIZE, libc::PROT_NONE);
            Stack {
                base: base as *mut u8,
                len,
            }
        }
    }

    /// Initial stack pointer: the 16-byte aligned high end.
    pub fn top(&self) -> usize {
        (self.base as usize + self.len) & !15
    }
}

impl Drop for Stack {
    fn drop(&mut self) {
        unsafe { libc::munmap(self.base as *mut libc::c_void, self.len) };
    }
}

/// Stacks left by an unwind while still running on them; freed later.
static DEAD_STACKS: Mutex<Vec<Stack>> = Mutex::new(Vec::new());

/// Arguments of the call made on the new stack.
struct Call {
    ctx: *mut Context,
    fobj: u64,
    arg: u64,
}

extern "C" fn on_new_stack(call: *mut Call) -> u64 {
    unsafe {
        let c = &*call;
        let enter = crate::enter_fn();
        enter(c.ctx, c.fobj, crate::function_entry(c.fobj), 1, c.arg)
    }
}

/// Runs `f(arg)` on the stack whose initial SP is `top`, with no frame
/// pointer chain into the current stack.
#[cfg(target_arch = "x86_64")]
unsafe fn run_on_stack(top: usize, f: extern "C" fn(*mut Call) -> u64, arg: *mut Call) -> u64 {
    let ret: u64;
    unsafe {
        core::arch::asm!(
            "push rbp",
            "mov r12, rsp",
            "mov rsp, {top}",
            "xor ebp, ebp",
            "call {f}",
            "mov rsp, r12",
            "pop rbp",
            top = in(reg) top,
            f = in(reg) f,
            in("rdi") arg,
            lateout("rax") ret,
            out("r12") _,
            clobber_abi("C"),
        );
    }
    ret
}

/// `(%call-on-new-stack function arg)`: calls FUNCTION with ARG on a fresh
/// stack and returns its value. Called through a trampoline; `fp` is its
/// frame pointer, the top of the current segment.
///
/// # Safety
/// Must be called by compiled code with a valid context and function object.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_call_on_new_stack(
    ctx: *mut Context,
    fobj: u64,
    arg: u64,
    fp: usize,
) -> u64 {
    DEAD_STACKS.lock().unwrap().clear();
    // Owned by the boundary entry, so that an unwind can retire it.
    let stack = Box::into_raw(Box::new(Stack::new(STACK_SIZE)));
    unsafe {
        let mut seg = Segment {
            top_fp: fp,
            base_fp: (*ctx).stack_base_fp,
            prev: (*ctx).segments,
            soft_limit: (*ctx).stack_soft_limit,
            hard_limit: (*ctx).stack_hard_limit,
        };
        let limit = (*ctx).stack_limit;
        set_stack_limits(ctx, (*stack).base as usize + GUARD_SIZE, STACK_SIZE);
        let mut boundary = DynEntry {
            kind: DYN_STACK_BOUNDARY,
            prev: (*ctx).dynenv,
            fp,
            tag: 0,
            pend_target: stack as *mut DynEntry,
            pend_value: 0,
        };
        (*ctx).segments = &mut seg;
        (*ctx).dynenv = &mut boundary;
        let mut call = Call { ctx, fobj, arg };
        let ret = run_on_stack((*stack).top(), on_new_stack, &mut call);
        (*ctx).dynenv = boundary.prev;
        (*ctx).segments = seg.prev;
        (*ctx).stack_soft_limit = seg.soft_limit;
        (*ctx).stack_hard_limit = seg.hard_limit;
        (*ctx).stack_limit = limit;
        drop(Box::from_raw(stack));
        ret
    }
}

/// Called by the unwinder when it passes a boundary entry: leaves the new
/// stack and returns the frame pointer to continue unwinding from on the old
/// stack. The new stack is freed later, since the unwinder still runs on it.
///
/// # Safety
/// `entry` must be the boundary entry of the innermost active call.
pub unsafe fn leave_stack(ctx: *mut Context, entry: *mut DynEntry) -> usize {
    unsafe {
        let seg = (*ctx).segments;
        (*ctx).stack_base_fp = (*seg).base_fp;
        (*ctx).segments = (*seg).prev;
        (*ctx).stack_soft_limit = (*seg).soft_limit;
        (*ctx).stack_hard_limit = (*seg).hard_limit;
        (*ctx).stack_limit = (*seg).soft_limit;
        let stack = Box::from_raw((*entry).pend_target as *mut Stack);
        DEAD_STACKS.lock().unwrap().push(*stack);
        (*entry).fp
    }
}
