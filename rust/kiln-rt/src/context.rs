//! The context object (constraint C1): all dynamic state hangs off it.
//! Compiled code receives a pointer to it as the first argument.
//! Field offsets are part of the ABI;

use crate::gc::KilnMutator;
use crate::stack::Segment;

/// Words of the transfer area: CALL-ARGUMENTS-LIMIT is 3 (the register
/// arguments) more, MULTIPLE-VALUES-LIMIT 1 more.
pub const VALUES_MAX: usize = 1021;

#[repr(C)]
pub struct Context {
    /// Offset 0. Nonzero means a poll point must call the slow path (C4).
    /// Set with `request_poll`, which also raises `stack_limit` so that
    /// function entries, which only compare with it, take the slow path.
    pub poll_flag: u64,
    /// Offset 8. Innermost dynamic-environment entry, or null.
    pub dynenv: *mut DynEntry,
    /// Offset 16. Frame pointer of the `kiln_enter` frame that started the
    /// current stack's Lisp frames; the GC stack walk stops there.
    pub stack_base_fp: usize,
    /// Offset 24. Frame pointer of the trampoline through which compiled code
    /// last entered the runtime at a GC safepoint; the GC stack walk starts there.
    pub safepoint_fp: usize,
    /// Offset 32. MMTk mutator of this context.
    pub mutator: *mut KilnMutator,
    /// Offset 40. Suspended segments of Lisp frames (see stack.rs).
    pub segments: *mut Segment,
    /// Offset 48. Thread-local values of special variables, indexed by
    /// the symbol's TLS index (see special.rs). NO_TLS_VALUE means unbound
    /// in this context: use the global value.
    pub tls: *mut u64,
    /// Offset 56. Number of words of `values` that the GC must treat as
    /// roots. Normally 0: values are consumed right after a return. Set
    /// while compiled code turns multiple values into a list, which
    /// allocates.
    pub values_live: u64,
    /// Offset 64. Address of the cursor of this context's bump allocator
    /// (MMTk's default allocator): compiled code allocates small objects
    /// by bumping it, and calls `kiln_rt_alloc` when it would pass the
    /// limit.
    pub alloc_cursor: *mut usize,
    /// Offset 72. Address of the limit of the bump allocator.
    pub alloc_limit: *mut usize,
    /// Offset 80. Function entries call the poll slow path when their frame
    /// pointer is below it: the stack is nearly exhausted (stack.rs), or a
    /// poll is requested (`isize::MAX`: compiled code compares signed).
    /// Otherwise `stack_real_limit`.
    pub stack_limit: usize,
    /// Offset 88, last of the fields compiled code uses, so that its size
    /// does not move them. Transfer area: arguments beyond the register
    /// arguments, and return values beyond the first.
    pub values: [u64; VALUES_MAX],
    /// The soft and hard stack limits: `stack_real_limit` is the soft one,
    /// lowered to the hard one while a stack exhaustion is signaled. 0
    /// when the stack's bounds are not known.
    pub stack_soft_limit: usize,
    pub stack_hard_limit: usize,
    pub stack_real_limit: usize,
}

pub const CTX_STACK_BASE_FP: i32 = core::mem::offset_of!(Context, stack_base_fp) as i32;
const _: () = assert!(core::mem::offset_of!(Context, tls) == 48);
const _: () = assert!(core::mem::offset_of!(Context, stack_limit) == 80);
const _: () = assert!(core::mem::offset_of!(Context, values) == 88);
const _: () = assert!(core::mem::offset_of!(Context, values_live) == 56);
const _: () = assert!(core::mem::offset_of!(Context, alloc_cursor) == 64);
const _: () = assert!(core::mem::offset_of!(Context, alloc_limit) == 72);

impl Context {
    pub fn new() -> Box<Context> {
        let mut ctx = Box::new(Context {
            poll_flag: 0,
            dynenv: core::ptr::null_mut(),
            stack_base_fp: 0,
            safepoint_fp: 0,
            mutator: core::ptr::null_mut(),
            segments: core::ptr::null_mut(),
            tls: crate::special::new_tls_table(),
            values: [0; VALUES_MAX],
            values_live: 0,
            alloc_cursor: core::ptr::null_mut(),
            alloc_limit: core::ptr::null_mut(),
            stack_limit: 0,
            stack_soft_limit: 0,
            stack_hard_limit: 0,
            stack_real_limit: 0,
        });
        ctx.mutator = crate::gc::bind_mutator(&mut *ctx);
        let (cursor, limit) = unsafe { crate::gc::bump_pointer_fields(ctx.mutator) };
        ctx.alloc_cursor = cursor;
        ctx.alloc_limit = limit;
        ctx
    }
}

impl Context {
    /// Sets the stack limit; `stack_limit` keeps a pending poll request.
    pub fn set_stack_limit(&mut self, limit: usize) {
        self.stack_real_limit = limit;
        let pending = unsafe { core::ptr::read_volatile(&raw const self.poll_flag) } != 0;
        self.stack_limit = if pending { isize::MAX as usize } else { limit };
    }
}

/// Makes the next poll point of `ctx` call the slow path: loop polls read
/// the flag, function entries the stack limit. May run on another thread;
/// a lost update only delays the poll to the next loop poll.
///
/// # Safety
/// `ctx` must be valid.
pub unsafe fn request_poll(ctx: *mut Context) {
    unsafe {
        core::ptr::write_volatile(&raw mut (*ctx).poll_flag, 1);
        core::ptr::write_volatile(&raw mut (*ctx).stack_limit, isize::MAX as usize);
    }
}

pub const DYN_CATCH: u64 = 1;
pub const DYN_UNWIND_PROTECT: u64 = 2;
/// An unwind-protect whose cleanup is running because an unwind passed
/// through it. It stays linked so that the GC sees the pending value; an
/// unwind that passes it again just unlinks it.
pub const DYN_CLEANUP_RUNNING: u64 = 3;
/// Marks where `%call-on-new-stack` switched stacks (see stack.rs). `fp` is
/// the frame to continue unwinding from on the old stack; `pend_target`
/// owns the new stack.
pub const DYN_STACK_BOUNDARY: u64 = 4;
/// A block or tagbody that is the target of a non-local exit from a
/// closure (`kiln_rt_exit_to`). `tag` is a token unique to the activation;
/// the closure holds the token.
pub const DYN_EXIT_POINT: u64 = 5;
/// A dynamic binding of a special variable. `tag` is the symbol,
/// `pend_target` its TLS index (a raw integer), `pend_value` the value to
/// restore. Leaving it, normally or by an unwind, restores the old value.
pub const DYN_BIND: u64 = 6;
/// The bindings of a `progv`. `tag` is a list of (symbol . old TLS value)
/// conses; leaving restores each.
pub const DYN_PROGV: u64 = 7;
/// A range of tagged reference fields in this frame. `pend_target` is the
/// first field's address, `pend_value` is a raw word count, and `tag` is zero.
/// These fields are roots even when their containing object lives on the stack.
pub const DYN_STACK_ROOTS: u64 = 8;

/// A dynamic-environment entry. Allocated in a stack slot of the frame that
/// establishes it, and linked through `prev`. Layout is part of the ABI.
#[repr(C)]
pub struct DynEntry {
    /// Offset 0: dynamic-environment kind.
    pub kind: u64,
    /// Offset 8: enclosing entry.
    pub prev: *mut DynEntry,
    /// Offset 16: frame pointer of the establishing frame.
    pub fp: usize,
    /// Offset 24: catch tag (catch entries only). A Lisp object: the GC
    /// updates it (entries are roots, see gc.rs).
    pub tag: u64,
    /// Offset 32: pending unwind target, or the raw base of a stack reference range.
    pub pend_target: *mut DynEntry,
    /// Offset 40: pending Lisp value, or a raw word count for DYN_STACK_ROOTS.
    pub pend_value: u64,
}
