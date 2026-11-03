//! Object representation. See docs/07-m1-gc.md.
//!
//! A Lisp value is a 64-bit word:
//! - low bit 0: fixnum, value = word >> 1 (63-bit)
//! - low 3 bits 0b001: cons, address = word - 1
//! - low 3 bits 0b101: other object, address = word - 5
//!
//! Every object, conses included, starts with a header word:
//! bits 0..8 hold the kind, bits 8..64 the number of payload words for
//! variable-length kinds. Objects are 8-byte aligned. Heap objects live in
//! MMTk spaces; NIL, T, and objects emitted by the compiler (symbols,
//! function objects) are static data outside them.

pub const FIXNUM_MASK: u64 = 1;
pub const TAG_MASK: u64 = 7;
pub const TAG_CONS: u64 = 1;
pub const TAG_GENERAL: u64 = 5;

pub const KIND_SYMBOL: u64 = 1;
pub const KIND_FUNCTION: u64 = 2;
pub const KIND_CONS: u64 = 3;
pub const KIND_SIMPLE_VECTOR: u64 = 4;

pub const KIND_MASK: u64 = 0xff;
pub const LENGTH_SHIFT: u32 = 8;

/// Layout: [header, car, cdr].
pub const CONS_BYTES: usize = 24;

/// Marks an unbound symbol value. An immediate (low bits 0b011), so the
/// GC ignores it.
pub const UNBOUND: u64 = 0x13;

/// Layout: [header, name pointer, name length, function, value].
/// Statically allocated. `function` is the global function cell (a
/// function object, or the module's undefined-function object); `value`
/// is the global value or UNBOUND. Both may point into the heap, so the
/// compiler registers them as static roots.
#[repr(C)]
pub struct SymbolObj {
    pub header: u64,
    pub name: *const u8,
    pub len: u64,
    pub function: u64,
    pub value: u64,
}

unsafe impl Sync for SymbolObj {}

/// Layout: [header (env length << 8), entry address, env...]. The env
/// words hold the closed-over values of a closure.
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
    function: 0,
    value: 0, // NIL's value is NIL; never read through this slot.
};

#[unsafe(no_mangle)]
pub static kiln_t: SymbolObj = SymbolObj {
    header: KIND_SYMBOL,
    name: b"T".as_ptr(),
    len: 1,
    function: 0,
    value: 0,
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

pub fn is_cons(v: u64) -> bool {
    v & TAG_MASK == TAG_CONS
}

pub fn is_general(v: u64) -> bool {
    v & TAG_MASK == TAG_GENERAL
}

/// Is `v` a pointer to an object (cons or other)?
pub fn is_pointer(v: u64) -> bool {
    is_cons(v) || is_general(v)
}

/// Address of the object `v` points to.
pub fn untag(v: u64) -> usize {
    (v & !TAG_MASK) as usize
}

/// Payload size in bytes of an object, from its header. The header word
/// itself is included.
pub fn object_bytes(header: u64) -> usize {
    match header & KIND_MASK {
        KIND_CONS => CONS_BYTES,
        KIND_SIMPLE_VECTOR => 8 + 8 * (header >> LENGTH_SHIFT) as usize,
        KIND_SYMBOL => 40,
        KIND_FUNCTION => 16 + 8 * (header >> LENGTH_SHIFT) as usize,
        k => panic!("object_bytes: unknown kind {k}"),
    }
}

/// # Safety
/// `v` must point to a valid object.
pub unsafe fn header(v: u64) -> u64 {
    unsafe { *(untag(v) as *const u64) }
}

/// # Safety
/// `v` must be a cons.
pub unsafe fn car(v: u64) -> u64 {
    unsafe { *((untag(v) + 8) as *const u64) }
}

/// # Safety
/// `v` must be a cons.
pub unsafe fn cdr(v: u64) -> u64 {
    unsafe { *((untag(v) + 16) as *const u64) }
}

/// # Safety
/// `v` must be a valid Lisp value.
pub unsafe fn write_object(out: &mut String, v: u64) {
    use std::fmt::Write;
    if is_fixnum(v) {
        let _ = write!(out, "{}", fixnum_value(v));
    } else if is_cons(v) {
        out.push('(');
        let mut x = v;
        loop {
            unsafe { write_object(out, car(x)) };
            let next = unsafe { cdr(x) };
            if is_cons(next) {
                out.push(' ');
                x = next;
            } else {
                if next != nil() {
                    out.push_str(" . ");
                    unsafe { write_object(out, next) };
                }
                break;
            }
        }
        out.push(')');
    } else if is_general(v) {
        let h = unsafe { header(v) };
        match h & KIND_MASK {
            KIND_SYMBOL => {
                let s = unsafe { &*(untag(v) as *const SymbolObj) };
                let bytes = unsafe { std::slice::from_raw_parts(s.name, s.len as usize) };
                out.push_str(&String::from_utf8_lossy(bytes));
            }
            KIND_FUNCTION => {
                let _ = write!(out, "#<FUNCTION {:#x}>", v);
            }
            KIND_SIMPLE_VECTOR => {
                out.push_str("#(");
                let n = (h >> LENGTH_SHIFT) as usize;
                for i in 0..n {
                    if i > 0 {
                        out.push(' ');
                    }
                    let e = unsafe { *((untag(v) + 8 + 8 * i) as *const u64) };
                    unsafe { write_object(out, e) };
                }
                out.push(')');
            }
            k => {
                let _ = write!(out, "#<OBJECT kind={} {:#x}>", k, v);
            }
        }
    } else {
        let _ = write!(out, "#<UNKNOWN {:#x}>", v);
    }
}
