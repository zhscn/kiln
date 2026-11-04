//! Integers beyond the fixnum range (docs/09-m3-kernel.md §8).
//!
//! A bignum is [header (length << 8 | KIND_BIGNUM), digits...]: two's
//! complement, little-endian 64-bit digits, minimal length. Integers in the
//! fixnum range are always fixnums. The arithmetic itself uses num-bigint:
//! arguments are read into BigInts before anything is allocated, so a GC
//! during allocation cannot invalidate them.

use crate::context::Context;
use crate::object::{self, KIND_BIGNUM, KIND_MASK, LENGTH_SHIFT, TAG_GENERAL, header_length};
use crate::rtfun::{ERR_DIVISION_BY_ZERO, ERR_NOT_INTEGER, error_with};
use num_bigint::BigInt;
use num_integer::Integer;
use num_traits::{One, Signed, ToPrimitive, Zero};

const FIXNUM_MIN: i64 = -(1 << 62);
const FIXNUM_MAX: i64 = (1 << 62) - 1;

pub fn is_bignum(v: u64) -> bool {
    object::is_general(v) && unsafe { object::header(v) } & KIND_MASK == KIND_BIGNUM
}

pub fn is_integer(v: u64) -> bool {
    object::is_fixnum(v) || is_bignum(v)
}

/// # Safety
/// `v` must be a fixnum or a bignum.
pub unsafe fn to_bigint(v: u64) -> BigInt {
    if object::is_fixnum(v) {
        return BigInt::from(object::fixnum_value(v));
    }
    unsafe {
        let n = header_length(object::header(v));
        let digits = std::slice::from_raw_parts((object::untag(v) + 8) as *const u64, n);
        let bytes: Vec<u8> = digits.iter().flat_map(|d| d.to_le_bytes()).collect();
        BigInt::from_signed_bytes_le(&bytes)
    }
}

/// Converts `x` to a Lisp integer, allocating a bignum if needed.
///
/// # Safety
/// `ctx` must be the current context with `safepoint_fp` set.
pub unsafe fn from_bigint(ctx: *mut Context, x: &BigInt) -> u64 {
    if let Some(i) = x.to_i64()
        && (FIXNUM_MIN..=FIXNUM_MAX).contains(&i)
    {
        return (i << 1) as u64;
    }
    let mut bytes = x.to_signed_bytes_le();
    let sign = if x.is_negative() { 0xff } else { 0 };
    bytes.resize(bytes.len().next_multiple_of(8), sign);
    let n = bytes.len() / 8;
    unsafe {
        let p = crate::gc::alloc(ctx, 8 + 8 * n as u64, KIND_BIGNUM | ((n as u64) << LENGTH_SHIFT));
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), (p + 8) as *mut u8, bytes.len());
        p + TAG_GENERAL
    }
}

unsafe fn integer_arg(ctx: *mut Context, v: u64) -> BigInt {
    if !is_integer(v) {
        unsafe { error_with(ctx, ERR_NOT_INTEGER, v) }
    }
    unsafe { to_bigint(v) }
}

pub const OP_ADD: u64 = 0;
pub const OP_SUB: u64 = 1;
pub const OP_MUL: u64 = 2;
pub const OP_TRUNCATE: u64 = 3;
pub const OP_FLOOR: u64 = 4;
pub const OP_CEILING: u64 = 5;
pub const OP_ROUND: u64 = 6;
pub const OP_COMPARE: u64 = 7;
pub const OP_LOGAND: u64 = 8;
pub const OP_LOGIOR: u64 = 9;
pub const OP_LOGXOR: u64 = 10;
pub const OP_ASH: u64 = 11;
pub const OP_GCD: u64 = 12;
pub const OP_EXPT: u64 = 13;
pub const OP_INTEGER_LENGTH: u64 = 14;

/// Rounds to nearest, ties to even (CL ROUND).
fn round_div(a: &BigInt, b: &BigInt) -> (BigInt, BigInt) {
    let (q, r) = a.div_mod_floor(b);
    let twice: BigInt = &r * 2;
    let babs = b.abs();
    let tabs = twice.abs();
    // r has the sign of b (floor); compare |2r| with |b|.
    let up = tabs > babs || (tabs == babs && q.is_odd());
    if up { (&q + 1, r - b) } else { (q, r) }
}

/// Integer operation `op` on `a` and `b` (fixnums or bignums). Division
/// operators return the quotient and store the remainder in
/// `ctx.values[0]` (two values). COMPARE returns -1, 0 or 1 as a fixnum.
/// Called through a trampoline; `fp` is its frame pointer.
///
/// # Safety
/// Must be called by compiled code with a valid context.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_integer_op(ctx: *mut Context, op: u64, a: u64, b: u64, fp: usize) -> u64 {
    unsafe {
        (*ctx).safepoint_fp = fp;
        let x = integer_arg(ctx, a);
        let y = if op == OP_INTEGER_LENGTH { BigInt::zero() } else { integer_arg(ctx, b) };
        let divide = |q: BigInt, r: BigInt| -> u64 {
            // The remainder is allocated first and kept in ctx.values,
            // which is not a root: allocate the quotient before storing it.
            let rv = from_bigint(ctx, &r);
            (*ctx).values[0] = rv;
            (*ctx).values_live = 1;
            let qv = from_bigint(ctx, &q);
            (*ctx).values_live = 0;
            qv
        };
        if (OP_TRUNCATE..=OP_ROUND).contains(&op) && y.is_zero() {
            error_with(ctx, ERR_DIVISION_BY_ZERO, a);
        }
        match op {
            OP_ADD => from_bigint(ctx, &(x + y)),
            OP_SUB => from_bigint(ctx, &(x - y)),
            OP_MUL => from_bigint(ctx, &(x * y)),
            OP_TRUNCATE => {
                let (q, r) = x.div_rem(&y);
                divide(q, r)
            }
            OP_FLOOR => {
                let (q, r) = x.div_mod_floor(&y);
                divide(q, r)
            }
            OP_CEILING => {
                let (q, r) = x.div_mod_floor(&y);
                if r.is_zero() { divide(q, r) } else { divide(q + 1, r - &y) }
            }
            OP_ROUND => {
                let (q, r) = round_div(&x, &y);
                divide(q, r)
            }
            OP_COMPARE => ((x.cmp(&y) as i64) << 1) as u64,
            OP_LOGAND => from_bigint(ctx, &(x & y)),
            OP_LOGIOR => from_bigint(ctx, &(x | y)),
            OP_LOGXOR => from_bigint(ctx, &(x ^ y)),
            OP_ASH => {
                let s = y.to_i64().unwrap_or(0);
                if s >= 0 {
                    from_bigint(ctx, &(x << s as usize))
                } else {
                    // Arithmetic shift right rounds toward negative infinity.
                    from_bigint(ctx, &(x >> (-s) as usize))
                }
            }
            OP_GCD => from_bigint(ctx, &x.gcd(&y)),
            OP_EXPT => {
                let e = y.to_u32().unwrap_or(0);
                let mut r = BigInt::one();
                for _ in 0..e {
                    r *= &x;
                }
                from_bigint(ctx, &r)
            }
            OP_INTEGER_LENGTH => {
                let bits = if x.is_negative() { (-(x + BigInt::one())).bits() } else { x.bits() };
                bits << 1
            }
            _ => crate::rtfun::error_exit("kiln_rt_integer_op: unknown operation"),
        }
    }
}
