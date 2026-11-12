//! Snapshot compiler records before allocating in the moving Lisp heap.
use crate::{packet, sexp::Sexp};
use kiln_rt::context::Context;
use kiln_rt::object::{self, *};

fn charge(remaining: &mut usize, bytes: usize) -> Result<(), String> {
    *remaining = remaining
        .checked_sub(bytes)
        .ok_or("backend program exceeds size limit")?;
    Ok(())
}

/// # Safety
/// Values must be valid Lisp objects, with no safepoint during traversal.
unsafe fn snapshot(value: u64, depth: u32, remaining: &mut usize) -> Result<Sexp, String> {
    if depth > packet::schema::MAX_DEPTH || *remaining < packet::schema::RECORD_SIZE as usize {
        return Err("backend program exceeds traversal limits".into());
    }
    *remaining -= packet::schema::RECORD_SIZE as usize;
    unsafe {
        if value == nil() {
            return Ok(Sexp::List(vec![]));
        }
        if is_fixnum(value) {
            return Ok(Sexp::Int(fixnum_value(value)));
        }
        if is_cons(value) {
            let mut items = Vec::new();
            let mut tail = value;
            while is_cons(tail) {
                charge(remaining, 4)?;
                items.push(snapshot(car(tail), depth + 1, remaining)?);
                tail = cdr(tail);
            }
            if tail != nil() {
                return Err("backend program has a dotted list".into());
            }
            return Ok(Sexp::List(items));
        }
        if is_general(value) {
            let h = header(value);
            return match h & KIND_MASK {
                KIND_STRING => {
                    let text = string_value(value);
                    charge(remaining, text.len())?;
                    Ok(Sexp::Str(text))
                }
                KIND_SYMBOL => {
                    let name = (*(untag(value) as *const SymbolObj)).name;
                    let text = string_value(name).to_ascii_lowercase();
                    charge(remaining, text.len())?;
                    Ok(Sexp::Sym(text))
                }
                KIND_BIGNUM => i64::try_from(kiln_rt::bignum::to_bigint(value))
                    .map(Sexp::Int)
                    .map_err(|_| "backend integer is outside signed 64-bit range".into()),
                KIND_SIMPLE_VECTOR if header_length(h) >= 2 => {
                    let words = (untag(value) + 8) as *const u64;
                    let c = *words;
                    let n = *words.add(1);
                    if !is_character(c) || !is_fixnum(n) {
                        return Err("invalid backend variable".into());
                    }
                    let c = char::from_u32((c >> CHARACTER_SHIFT) as u32)
                        .ok_or("invalid variable prefix")?;
                    let text = format!("{c}{}", fixnum_value(n));
                    charge(remaining, text.len())?;
                    Ok(Sexp::Sym(text))
                }
                _ => Err("unsupported backend program object".into()),
            };
        }
        Err("unsupported backend program value".into())
    }
}

/// Copies the program into Rust ownership without a Lisp allocation.
///
/// # Safety
/// PROGRAM must be a valid Lisp value; no moving GC may run during traversal.
pub(crate) unsafe fn snapshot_program(program: u64) -> Result<Sexp, String> {
    let mut remaining = packet::schema::MAX_EXPANDED_BYTES as usize;
    unsafe { snapshot(program, 1, &mut remaining) }
}

/// Build canonical wire records directly; atom identities are valid only
/// in this no-safepoint window and are discarded before allocating Lisp data.
unsafe fn encode_heap(program: u64, language: u32) -> Result<Vec<u8>, String> {
    struct Walker {
        builder: packet::RecordBuilder,
        atoms: std::collections::HashMap<u64, u32>,
        remaining: usize,
    }
    impl Walker {
        unsafe fn node(&mut self, value: u64, depth: u32) -> Result<u32, String> {
            if depth > packet::schema::MAX_DEPTH {
                return Err("backend nesting limit exceeded".into());
            }
            charge(
                &mut self.remaining,
                packet::schema::EXPANSION_RECORD_BYTES as usize,
            )?;
            unsafe {
                if value == nil() {
                    return self.builder.list(&[]);
                }
                if let Some(id) = self.atoms.get(&value) {
                    return Ok(*id);
                }
                if is_cons(value) {
                    let mut children = Vec::new();
                    let mut tail = value;
                    while is_cons(tail) {
                        children.push(self.node(car(tail), depth + 1)?);
                        tail = cdr(tail);
                    }
                    if tail != nil() {
                        return Err("backend program has a dotted list".into());
                    }
                    return self.builder.list(&children);
                }
                let id = if is_fixnum(value) {
                    self.builder.integer(fixnum_value(value))?
                } else if is_general(value) {
                    let h = header(value);
                    match h & KIND_MASK {
                        KIND_SYMBOL => {
                            let name = (*(untag(value) as *const SymbolObj)).name;
                            self.builder
                                .text(&string_value(name).to_ascii_lowercase(), true)?
                        }
                        KIND_STRING => self.builder.text(&string_value(value), false)?,
                        KIND_BIGNUM => self.builder.integer(
                            i64::try_from(kiln_rt::bignum::to_bigint(value))
                                .map_err(|_| "backend integer is outside signed 64-bit range")?,
                        )?,
                        KIND_SIMPLE_VECTOR if header_length(h) >= 2 => {
                            let words = (untag(value) + 8) as *const u64;
                            let c = *words;
                            let n = *words.add(1);
                            if !is_character(c) || !is_fixnum(n) {
                                return Err("invalid backend variable".into());
                            }
                            let c = char::from_u32((c >> CHARACTER_SHIFT) as u32)
                                .ok_or("invalid variable prefix")?;
                            self.builder
                                .text(&format!("{c}{}", fixnum_value(n)), true)?
                        }
                        _ => return Err("unsupported backend program object".into()),
                    }
                } else {
                    return Err("unsupported backend program value".into());
                };
                self.atoms.insert(value, id);
                Ok(id)
            }
        }
    }
    let mut walker = Walker {
        builder: Default::default(),
        atoms: Default::default(),
        remaining: packet::schema::MAX_EXPANDED_BYTES as usize,
    };
    let root = unsafe { walker.node(program, 1) }?;
    walker.builder.finish(root, language)
}

/// Encode a whole program with one native call. No Lisp pointer survives
/// snapshotting: only then may allocating the result vector trigger GC.
///
/// # Safety
/// Must be called through a safepoint trampoline with a valid context and
/// valid Lisp arguments. Traversal assumes the current single mutator.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_encode_packet(
    ctx: *mut Context,
    program: u64,
    language: u64,
    fp: usize,
) -> u64 {
    let result = (|| {
        if !is_fixnum(language) {
            return Err("packet language must be a fixnum".to_string());
        }
        let language =
            u32::try_from(fixnum_value(language)).map_err(|_| "invalid packet language")?;
        unsafe { encode_heap(program, language) }
    })();
    match result {
        Ok(bytes) => unsafe {
            let n = bytes.len();
            let address = kiln_rt::gc::kiln_rt_alloc(
                ctx,
                (n as u64 + 1) * 8,
                KIND_SIMPLE_VECTOR | ((n as u64) << LENGTH_SHIFT),
                fp,
            );
            let words = (address + 8) as *mut u64;
            for (i, byte) in bytes.into_iter().enumerate() {
                *words.add(i) = u64::from(byte) << 1;
            }
            address + TAG_GENERAL
        },
        Err(error) => {
            eprintln!("kiln_rt_encode_packet: {error}");
            object::nil()
        }
    }
}

/// Write a serialized program without allocating a Lisp byte carrier.
/// Returns bytes written, minus errno, or -1000 for an invalid program,
/// all encoded as fixnums.
///
/// # Safety
/// PROGRAM must be a valid Lisp value; the current single mutator cannot
/// reach a safepoint until the program snapshot has been completed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_write_packet(_ctx: *mut Context, program: u64, fd: u64) -> u64 {
    let fixnum = |n: i64| (n << 1) as u64;
    if !is_fixnum(fd) {
        return fixnum(-i64::from(libc::EBADF));
    }
    let Ok(fd) = libc::c_int::try_from(fixnum_value(fd)) else {
        return fixnum(-i64::from(libc::EBADF));
    };
    let bytes = unsafe { encode_heap(program, packet::schema::KIR_PAYLOAD) };
    let Ok(bytes) = bytes else {
        return fixnum(-1000);
    };
    let mut done = 0;
    while done < bytes.len() {
        let n = unsafe { libc::write(fd, bytes[done..].as_ptr().cast(), bytes.len() - done) };
        if n < 0 {
            let errno = std::io::Error::last_os_error()
                .raw_os_error()
                .unwrap_or(libc::EIO);
            if errno == libc::EINTR {
                continue;
            }
            return fixnum(-i64::from(errno));
        }
        if n == 0 {
            return fixnum(-i64::from(libc::EIO));
        }
        done += n as usize;
    }
    fixnum(done as i64)
}
