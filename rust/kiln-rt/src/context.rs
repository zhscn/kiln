//! The context object (constraint C1): all dynamic state hangs off it.
//! Compiled code receives a pointer to it as the first argument.
//! Field offsets are part of the ABI; see docs/06-m0-abi.md.

pub const VALUES_MAX: usize = 64;

#[repr(C)]
pub struct Context {
    /// Offset 0. Nonzero means a poll point must call the slow path (C4).
    pub poll_flag: u64,
    /// Offset 8. Innermost dynamic-environment entry, or null.
    pub dynenv: *mut DynEntry,
    /// Offset 16. Extra return values beyond the first (unused in M0).
    pub values: [u64; VALUES_MAX],
}

impl Context {
    pub fn new() -> Box<Context> {
        Box::new(Context {
            poll_flag: 0,
            dynenv: core::ptr::null_mut(),
            values: [0; VALUES_MAX],
        })
    }
}

pub const DYN_CATCH: u64 = 1;
pub const DYN_UNWIND_PROTECT: u64 = 2;

/// A dynamic-environment entry. Allocated in a stack slot of the frame that
/// establishes it, and linked through `prev`. Layout is part of the ABI.
#[repr(C)]
pub struct DynEntry {
    /// Offset 0: DYN_CATCH or DYN_UNWIND_PROTECT.
    pub kind: u64,
    /// Offset 8: enclosing entry.
    pub prev: *mut DynEntry,
    /// Offset 16: frame pointer of the establishing frame.
    pub fp: usize,
    /// Offset 24: catch tag (catch entries only).
    pub tag: u64,
    /// Offset 32: pending unwind target while a cleanup runs.
    pub pend_target: *mut DynEntry,
    /// Offset 40: pending unwind value while a cleanup runs.
    pub pend_value: u64,
}
