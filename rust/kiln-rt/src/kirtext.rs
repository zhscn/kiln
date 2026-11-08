//! Writing KIR forms as text (`kiln_rt_write_kir`).
//!
//! The compiler builds a module's KIR as Lisp lists and writes it, form by
//! form, to the module's `.kir` file. Printing it in Lisp, a character at a
//! time through a stream, was a fifth of kiln compiling itself; this writes
//! the same text from the objects directly. The text must be byte for byte
//! what `out-kir` (lisp/kir.lisp) makes, which the host (SBCL) still uses:
//! the bootstrap compares the files.
//!
//! A form is made of:
//! - lists (proper; a dotted tail is ignored, as `out-kir`'s `loop ... on`
//!   does), NIL printed as `()`;
//! - keywords, printed in lower case;
//! - strings, in double quotes, `"` and `\` escaped with `\`;
//! - integers, in decimal;
//! - variables, blocks and slots: simple vectors `#(char number ...)`,
//!   printed as the character followed by the number (`v12`).
//!
//! The whole call runs without a safepoint, so no object moves while it
//! reads them.

use crate::context::Context;
use crate::object::{
    KIND_BIGNUM, KIND_SIMPLE_VECTOR, KIND_STRING, KIND_SYMBOL, car, cdr, fixnum_value,
    header, header_length, is_character, is_cons, is_fixnum, is_general, nil, untag,
    CHARACTER_SHIFT, KIND_MASK,
};
use std::fmt::Write as _;

/// Appends the text of the KIR form `v` to `out`; Err for an object that
/// is not part of KIR.
///
/// # Safety
/// `v` must be a valid Lisp value, and no GC may run during the call.
pub unsafe fn write_form(out: &mut String, v: u64) -> Result<(), String> {
    unsafe {
        if v == nil() {
            out.push_str("()");
        } else if is_fixnum(v) {
            let _ = write!(out, "{}", fixnum_value(v));
        } else if is_cons(v) {
            out.push('(');
            let mut tail = v;
            let mut first = true;
            while is_cons(tail) {
                if !first {
                    out.push(' ');
                }
                first = false;
                write_form(out, car(tail))?;
                tail = cdr(tail);
            }
            out.push(')');
        } else if is_general(v) {
            let h = header(v);
            match h & KIND_MASK {
                KIND_SYMBOL => {
                    let name = *((untag(v) + 8) as *const u64);
                    for c in string_chars(name) {
                        out.push(c.to_ascii_lowercase());
                    }
                }
                KIND_STRING => {
                    out.push('"');
                    for c in string_chars(v) {
                        if c == '"' || c == '\\' {
                            out.push('\\');
                        }
                        out.push(c);
                    }
                    out.push('"');
                }
                KIND_BIGNUM => {
                    let _ = write!(out, "{}", crate::bignum::to_bigint(v));
                }
                KIND_SIMPLE_VECTOR if header_length(h) >= 2 => {
                    let words = (untag(v) + 8) as *const u64;
                    let c = *words;
                    let n = *words.add(1);
                    if !is_character(c) || !is_fixnum(n) {
                        return Err("malformed KIR variable".into());
                    }
                    out.push(char::from_u32((c >> CHARACTER_SHIFT) as u32).unwrap_or('?'));
                    let _ = write!(out, "{}", fixnum_value(n));
                }
                k => return Err(format!("object of kind {k} in KIR")),
            }
        } else {
            return Err(format!("value {v:#x} in KIR"));
        }
        Ok(())
    }
}

unsafe fn string_chars(s: u64) -> impl Iterator<Item = char> {
    unsafe {
        let n = header_length(header(s));
        let codes = std::slice::from_raw_parts((untag(s) + 8) as *const u32, n);
        codes.iter().map(|&c| char::from_u32(c).unwrap_or('\u{fffd}'))
    }
}

/// Writes the text of the KIR form `form` to the file descriptor `fd` (a
/// fixnum). Returns the number of bytes written as a fixnum, or a negative
/// fixnum: minus errno if writing failed, -1000 if `form` is not KIR.
///
/// # Safety
/// `form` must be a valid Lisp value.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_write_kir(_ctx: *mut Context, form: u64, fd: u64) -> u64 {
    let fixnum = |n: i64| (n << 1) as u64;
    let mut text = String::new();
    if unsafe { write_form(&mut text, form) }.is_err() {
        return fixnum(-1000);
    }
    let bytes = text.as_bytes();
    let fd = fixnum_value(fd) as libc::c_int;
    let mut done = 0;
    while done < bytes.len() {
        let n = unsafe {
            libc::write(fd, bytes[done..].as_ptr() as *const libc::c_void, bytes.len() - done)
        };
        if n < 0 {
            let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(1);
            if errno == libc::EINTR {
                continue;
            }
            return fixnum(-(errno as i64));
        }
        done += n as usize;
    }
    fixnum(bytes.len() as i64)
}
