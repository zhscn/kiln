//! Object representation (M0 subset). See docs/06-m0-abi.md.
//!
//! A Lisp value is a 64-bit word:
//! - low bit 0: fixnum, value = word >> 1 (63-bit)
//! - low 3 bits 0b101: pointer to a general object, address = word - 5
//!
//! A general object starts with a header word holding its kind.

pub const FIXNUM_MASK: u64 = 1;
pub const TAG_MASK: u64 = 7;
pub const TAG_GENERAL: u64 = 5;

pub const KIND_SYMBOL: u64 = 1;
pub const KIND_FUNCTION: u64 = 2;

/// Layout: [header, name pointer, name length]. Statically allocated in M0.
#[repr(C)]
pub struct SymbolObj {
    pub header: u64,
    pub name: *const u8,
    pub len: u64,
}

unsafe impl Sync for SymbolObj {}

/// Layout: [header, entry address].
#[repr(C)]
pub struct FunctionObj {
    pub header: u64,
    pub entry: *const u8,
}

unsafe impl Sync for FunctionObj {}

#[unsafe(no_mangle)]
pub static kiln_nil: SymbolObj = SymbolObj {
    header: KIND_SYMBOL,
    name: b"NIL".as_ptr(),
    len: 3,
};

#[unsafe(no_mangle)]
pub static kiln_t: SymbolObj = SymbolObj {
    header: KIND_SYMBOL,
    name: b"T".as_ptr(),
    len: 1,
};

pub fn tag_general<T>(p: *const T) -> u64 {
    p as u64 + TAG_GENERAL
}

pub fn nil() -> u64 {
    tag_general(&kiln_nil)
}

pub fn is_fixnum(v: u64) -> bool {
    v & FIXNUM_MASK == 0
}

pub fn fixnum_value(v: u64) -> i64 {
    (v as i64) >> 1
}

pub fn is_general(v: u64) -> bool {
    v & TAG_MASK == TAG_GENERAL
}

/// # Safety
/// `v` must be a valid tagged general object.
pub unsafe fn header(v: u64) -> u64 {
    unsafe { *((v - TAG_GENERAL) as *const u64) }
}

/// # Safety
/// `v` must be a valid Lisp value.
pub unsafe fn write_object(out: &mut String, v: u64) {
    use std::fmt::Write;
    if is_fixnum(v) {
        let _ = write!(out, "{}", fixnum_value(v));
    } else if is_general(v) {
        match unsafe { header(v) } {
            KIND_SYMBOL => {
                let s = unsafe { &*((v - TAG_GENERAL) as *const SymbolObj) };
                let bytes = unsafe { std::slice::from_raw_parts(s.name, s.len as usize) };
                out.push_str(&String::from_utf8_lossy(bytes));
            }
            KIND_FUNCTION => {
                let _ = write!(out, "#<FUNCTION {:#x}>", v);
            }
            k => {
                let _ = write!(out, "#<OBJECT kind={} {:#x}>", k, v);
            }
        }
    } else {
        let _ = write!(out, "#<UNKNOWN {:#x}>", v);
    }
}
