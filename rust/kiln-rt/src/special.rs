//! Special variables (constraint C1): TLS-index scheme.
//!
//! A symbol gets a TLS index the first time it is dynamically bound
//! (index 0 means none yet). Each context has a table of TLS_SIZE words
//! indexed by it; NO_TLS_VALUE in a slot means the symbol is not bound in
//! that context, so its global value (the symbol's value cell) applies.
//! Slot 0 always holds NO_TLS_VALUE, so compiled code can index the table
//! with a symbol's index without first testing it for 0.
//!
//! Binding saves the old slot value in a DYN_BIND dynamic-environment
//! entry; leaving the binding, normally or by an unwind, restores it.
//! Switching contexts (threads, later fibers) switches tables: O(1).

use crate::context::{Context, DynEntry};
use crate::object::untag;
use std::sync::Mutex;

/// Marks an empty TLS slot. An immediate (low bits 0b011), ignored by the GC.
pub const NO_TLS_VALUE: u64 = 0x23;
pub const TLS_SIZE: usize = 4096;
/// Byte offset of the TLS index in a symbol (untagged).
const SYMBOL_TLS_INDEX: usize = 40;

static NEXT_INDEX: Mutex<u64> = Mutex::new(1);

pub fn new_tls_table() -> *mut u64 {
    Box::into_raw(vec![NO_TLS_VALUE; TLS_SIZE].into_boxed_slice()) as *mut u64
}

/// Number of TLS indexes handed out so far (including the unused 0).
pub fn tls_used() -> usize {
    *NEXT_INDEX.lock().unwrap() as usize
}

/// Returns the TLS index of the symbol `sym`, assigning one if needed.
/// Not a safepoint.
///
/// # Safety
/// `sym` must be a tagged symbol.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_tls_index(_ctx: *mut Context, sym: u64) -> u64 {
    let cell = (untag(sym) + SYMBOL_TLS_INDEX) as *mut u64;
    let mut next = NEXT_INDEX.lock().unwrap();
    unsafe {
        if *cell == 0 {
            if *next as usize >= TLS_SIZE {
                crate::rtfun::error_exit("too many special variables (TLS table full)");
            }
            *cell = *next;
            *next += 1;
        }
        *cell
    }
}

/// Undoes the binding recorded in `entry` (called by the unwinder).
///
/// # Safety
/// `entry` must be a DYN_BIND entry of `ctx`.
pub unsafe fn unbind(ctx: *mut Context, entry: *mut DynEntry) {
    unsafe {
        let index = (*entry).pend_target as usize;
        *(*ctx).tls.add(index) = (*entry).pend_value;
    }
}

/// Undoes the bindings of a `progv` entry (called by the unwinder).
///
/// # Safety
/// `entry` must be a DYN_PROGV entry of `ctx`.
pub unsafe fn unbind_progv(ctx: *mut Context, entry: *mut DynEntry) {
    use crate::object::{car, cdr, is_cons};
    unsafe {
        let mut l = (*entry).tag;
        while is_cons(l) {
            let pair = car(l);
            let index = *((untag(car(pair)) + SYMBOL_TLS_INDEX) as *const u64) as usize;
            *(*ctx).tls.add(index) = cdr(pair);
            l = cdr(l);
        }
    }
}
