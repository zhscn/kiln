//! Object representation.
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
/// UTF-32 string: [header (length << 8), code points...], padded to 8 bytes.
pub const KIND_STRING: u64 = 5;
/// Integer outside the fixnum range: [header (length << 8), digits...],
/// two's complement, little-endian 64-bit digits, minimal length.
pub const KIND_BIGNUM: u64 = 6;
/// [header, numerator, denominator], normalized.
pub const KIND_RATIO: u64 = 7;
/// [header, IEEE 754 binary64 bits].
pub const KIND_DOUBLE: u64 = 8;
/// Standard object: [header, rack].
pub const KIND_INSTANCE: u64 = 9;
/// Funcallable standard object: [header, entry, rack, function]. A
/// function too: kinds 2 and 10 differ only in bit 3.
pub const KIND_FUNCALLABLE_INSTANCE: u64 = 10;
/// Rack: [header (length << 8), class, stamp, slot list, slots...].
pub const KIND_RACK: u64 = 11;
/// Complex number: [header, real part, imaginary part], both rationals
/// or both floats of the same format; a rational complex has a nonzero
/// imaginary part.
pub const KIND_COMPLEX: u64 = 12;
/// Structure: [header (slot count << 8), layout, slots...].
pub const KIND_STRUCTURE_INSTANCE: u64 = 13;

/// Immediates: low 3 bits 0b011, bits 3..8 the immediate kind, payload
/// from bit 8.
pub const IMMEDIATE_MASK: u64 = 0xff;
pub const CHARACTER_TAG: u64 = 0x0b;
pub const CHARACTER_SHIFT: u32 = 8;

pub const KIND_MASK: u64 = 0xff;
pub const LENGTH_SHIFT: u32 = 8;
/// The length field is bits 8..40; bits 40..64 hold the identity hash
/// (0 until assigned, see `kiln_rt_identity_hash`).
pub const LENGTH_MASK: u64 = 0xffff_ffff;
pub const HASH_SHIFT: u32 = 40;

/// The length field of a header.
pub fn header_length(h: u64) -> usize {
    ((h >> LENGTH_SHIFT) & LENGTH_MASK) as usize
}

/// Layout: [header, car, cdr].
pub const CONS_BYTES: usize = 24;

/// Marks an unbound symbol value. An immediate (low bits 0b011), so the
/// GC ignores it.
pub const UNBOUND: u64 = 0x13;

/// Value of an unbound slot of a standard object (lisp/abi.lisp).
pub const UNBOUND_SLOT: u64 = 0x2b;

/// Layout: [header, name, package, function, value, TLS index, plist,
/// setf function].
/// `name` is a string object; `package` the package (NIL when
/// uninterned; the compiler emits the package's name as a string, which
/// the package system replaces with the package object); the
/// TLS index is a fixnum, 0 until first bound (special.rs). Symbols
/// emitted by the compiler are static; `package`, `function`, `value`,
/// `plist` and `setf_function` are registered as GC roots.
#[repr(C)]
pub struct SymbolObj {
    pub header: u64,
    pub name: u64,
    pub package: u64,
    pub function: u64,
    pub value: u64,
    pub tls_index: u64,
    pub plist: u64,
    /// The function named (SETF symbol).
    pub setf_function: u64,
}

pub const SYMBOL_BYTES: usize = 64;

/// Layout: [header (env length << 8), entry address, env...]. The env
/// words hold the closed-over values of a closure.
#[repr(C)]
pub struct FunctionObj {
    pub header: u64,
    pub entry: *const u8,
}

unsafe impl Sync for FunctionObj {}

/// A string in static memory.
#[repr(C)]
pub struct StaticString<const N: usize> {
    pub header: u64,
    pub chars: [u32; N],
}

const fn static_string<const N: usize>(s: &str) -> StaticString<N> {
    let bytes = s.as_bytes();
    let mut chars = [0u32; N];
    let mut i = 0;
    while i < bytes.len() {
        chars[i] = bytes[i] as u32;
        i += 1;
    }
    StaticString {
        header: KIND_STRING | ((bytes.len() as u64) << LENGTH_SHIFT),
        chars,
    }
}

static NIL_NAME: StaticString<4> = static_string("NIL");
static T_NAME: StaticString<2> = static_string("T");
static CL_NAME: StaticString<12> = static_string("COMMON-LISP");

/// NIL and T. Their name and package fields are filled in by
/// `init_statics` (constant evaluation cannot tag pointers).
#[unsafe(no_mangle)]
pub static mut kiln_nil: SymbolObj = SymbolObj {
    header: KIND_SYMBOL,
    name: 0,
    package: 0,
    function: 0,
    value: 0, // NIL's value is NIL; never read through this slot.
    tls_index: 0,
    plist: 0,
    setf_function: 0,
};

#[unsafe(no_mangle)]
pub static mut kiln_t: SymbolObj = SymbolObj {
    header: KIND_SYMBOL,
    name: 0,
    package: 0,
    function: 0,
    value: 0,
    tls_index: 0,
    plist: 0,
    setf_function: 0,
};

/// Fills in the fields of NIL and T. Called once before any Lisp code runs.
pub fn init_statics() {
    unsafe {
        let nil = nil();
        let cl = tag_general(&CL_NAME);
        let n = &raw mut kiln_nil;
        (*n).name = tag_general(&NIL_NAME);
        (*n).package = cl;
        (*n).plist = nil;
        let t = &raw mut kiln_t;
        (*t).name = tag_general(&T_NAME);
        (*t).package = cl;
        (*t).value = tag_general(&raw const kiln_t);
        (*t).plist = nil;
        // Their plists (and the other cells, for symmetry) can point into
        // the heap.
        let mut roots = Vec::new();
        for s in [n, t] {
            roots.push(&raw mut (*s).package as usize);
            roots.push(&raw mut (*s).function as usize);
            roots.push(&raw mut (*s).plist as usize);
            roots.push(&raw mut (*s).setf_function as usize);
        }
        crate::gc::register_static_roots(&roots);
    }
}

pub fn tag_general<T>(p: *const T) -> u64 {
    p as u64 + TAG_GENERAL
}

pub fn nil() -> u64 {
    tag_general(&raw const kiln_nil)
}

pub fn t() -> u64 {
    tag_general(&raw const kiln_t)
}

pub fn is_character(v: u64) -> bool {
    v & IMMEDIATE_MASK == CHARACTER_TAG
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
        KIND_SIMPLE_VECTOR => 8 + 8 * header_length(header),
        KIND_SYMBOL => SYMBOL_BYTES,
        KIND_STRING => 8 + (4 * header_length(header)).next_multiple_of(8),
        KIND_BIGNUM => 8 + 8 * header_length(header),
        KIND_RATIO | KIND_COMPLEX => 24,
        KIND_DOUBLE => 16,
        KIND_INSTANCE => 16,
        KIND_STRUCTURE_INSTANCE => 16 + 8 * header_length(header),
        KIND_FUNCALLABLE_INSTANCE => 32,
        KIND_RACK => 8 + 8 * header_length(header),
        KIND_FUNCTION => 16 + 8 * header_length(header),
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
                // A keyword: its package is KEYWORD (by name, before
                // package objects exist), and its value is itself.
                let keyword = if is_general(s.package)
                    && unsafe { header(s.package) } & KIND_MASK == KIND_STRING
                {
                    (unsafe { string_value(s.package) }) == "KEYWORD"
                } else {
                    s.value == v && v != tag_general(&raw const kiln_t)
                };
                if keyword {
                    out.push(':');
                }
                out.push_str(&unsafe { string_value(s.name) });
            }
            KIND_STRING => {
                out.push('"');
                for c in unsafe { string_value(v) }.chars() {
                    if c == '"' || c == '\\' {
                        out.push('\\');
                    }
                    out.push(c);
                }
                out.push('"');
            }
            KIND_FUNCTION => {
                let _ = write!(out, "#<FUNCTION {:#x}>", v);
            }
            KIND_BIGNUM => {
                let _ = write!(out, "{}", unsafe { crate::bignum::to_bigint(v) });
            }
            KIND_RATIO | KIND_DOUBLE => unsafe { crate::number::write_number(out, v) },
            KIND_COMPLEX => unsafe {
                let p = untag(v);
                out.push_str("#C(");
                write_object(out, *((p + 8) as *const u64));
                out.push(' ');
                write_object(out, *((p + 16) as *const u64));
                out.push(')');
            },
            KIND_INSTANCE => {
                let _ = write!(out, "#<STANDARD-OBJECT {:#x}>", v);
            }
            KIND_STRUCTURE_INSTANCE => {
                let _ = write!(out, "#<STRUCTURE-OBJECT {:#x}>", v);
            }
            KIND_FUNCALLABLE_INSTANCE => {
                let _ = write!(out, "#<FUNCALLABLE-INSTANCE {:#x}>", v);
            }
            KIND_SIMPLE_VECTOR => {
                out.push_str("#(");
                let n = header_length(h);
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
    } else if crate::number::is_single(v) {
        unsafe { crate::number::write_number(out, v) };
    } else if is_character(v) {
        let code = (v >> CHARACTER_SHIFT) as u32;
        out.push_str("#\\");
        match code {
            0x20 => out.push_str("Space"),
            0x0a => out.push_str("Newline"),
            0x09 => out.push_str("Tab"),
            0x0d => out.push_str("Return"),
            0x7f => out.push_str("Rubout"),
            0x08 => out.push_str("Backspace"),
            0x0c => out.push_str("Page"),
            0 => out.push_str("Null"),
            _ => match char::from_u32(code) {
                Some(c) if !c.is_control() => out.push(c),
                _ => {
                    let _ = write!(out, "U+{code:04X}");
                }
            },
        }
    } else if v == UNBOUND_SLOT {
        out.push_str("#<UNBOUND-SLOT>");
    } else {
        let _ = write!(out, "#<UNKNOWN {:#x}>", v);
    }
}

/// The contents of the string object `v`.
///
/// # Safety
/// `v` must be a string object.
pub unsafe fn string_value(v: u64) -> String {
    unsafe {
        let n = header_length(header(v));
        let chars = std::slice::from_raw_parts((untag(v) + 8) as *const u32, n);
        chars.iter().map(|&c| char::from_u32(c).unwrap_or('\u{fffd}')).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn structure_size_and_gc_fields_include_layout() {
        for slots in [0, 1, 31, 1024] {
            let header = KIND_STRUCTURE_INSTANCE | (slots << LENGTH_SHIFT) | (123 << HASH_SHIFT);
            assert_eq!(object_bytes(header), 16 + 8 * slots as usize);
            assert_eq!(crate::image::lisp_fields(header), (8, 1 + slots as usize));
        }
    }
}
