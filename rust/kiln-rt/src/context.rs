//! The context object (constraint C1): all dynamic state hangs off it.
//! Compiled code receives a pointer to it as the first argument.
//! Field offsets are part of the ABI; see docs/06-m0-abi.md and docs/07-m1-gc.md.

use crate::gc::KilnMutator;
use crate::stack::Segment;

pub const VALUES_MAX: usize = 64;

#[repr(C)]
pub struct Context {
    /// Offset 0. Nonzero means a poll point must call the slow path (C4).
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
    /// Offset 56. Transfer area: arguments beyond the register arguments,
    /// and later extra return values.
    pub values: [u64; VALUES_MAX],
    /// Offset 568. Number of words of `values` that the GC must treat as
    /// roots. Normally 0: values are consumed right after a return. Set
    /// while compiled code turns multiple values into a list, which
    /// allocates.
    pub values_live: u64,
}

pub const CTX_STACK_BASE_FP: i32 = core::mem::offset_of!(Context, stack_base_fp) as i32;
const _: () = assert!(core::mem::offset_of!(Context, tls) == 48);
const _: () = assert!(core::mem::offset_of!(Context, values) == 56);
const _: () = assert!(core::mem::offset_of!(Context, values_live) == 568);

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
        });
        ctx.mutator = crate::gc::bind_mutator(&mut *ctx);
        ctx
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

/// A dynamic-environment entry. Allocated in a stack slot of the frame that
/// establishes it, and linked through `prev`. Layout is part of the ABI.
#[repr(C)]
pub struct DynEntry {
    /// Offset 0: DYN_CATCH, DYN_UNWIND_PROTECT or DYN_CLEANUP_RUNNING.
    pub kind: u64,
    /// Offset 8: enclosing entry.
    pub prev: *mut DynEntry,
    /// Offset 16: frame pointer of the establishing frame.
    pub fp: usize,
    /// Offset 24: catch tag (catch entries only). A Lisp object: the GC
    /// updates it (entries are roots, see gc.rs).
    pub tag: u64,
    /// Offset 32: pending unwind target while a cleanup runs.
    pub pend_target: *mut DynEntry,
    /// Offset 40: pending unwind value while a cleanup runs. A Lisp object.
    pub pend_value: u64,
}
