//! Integers beyond the fixnum range.
//!
//! A bignum is [header (length << 8 | KIND_BIGNUM), digits...]: two's
//! complement, little-endian 64-bit digits, minimal length. Integers in the
//! fixnum range are always fixnums. The arithmetic itself uses num-bigint:
//! arguments are read into BigInts before anything is allocated, so a GC
//! during allocation cannot invalidate them.

use crate::context::Context;
use crate::object::{self, KIND_BIGNUM, KIND_MASK, LENGTH_SHIFT, TAG_GENERAL, header_length};
use crate::rtfun::{ERR_DIVISION_BY_ZERO, ERR_NOT_INTEGER, error_with};
use num_bigint::{BigInt, BigUint};
use num_integer::Integer;
use num_traits::{One, Signed, ToPrimitive, Zero};

const FIXNUM_MIN: i64 = -(1 << 62);
const FIXNUM_MAX: i64 = (1 << 62) - 1;

pub fn is_bignum(v: u64) -> bool {
    object::is_general(v) && unsafe { object::header(v) } & KIND_MASK == KIND_BIGNUM
}

/// # Safety
/// `v` must be a bignum.
pub(crate) unsafe fn bignum_is_negative(v: u64) -> bool {
    unsafe {
        let length = header_length(object::header(v));
        *((object::untag(v) + 8 * length) as *const i64) < 0
    }
}

pub fn is_integer(v: u64) -> bool {
    object::is_fixnum(v) || is_bignum(v)
}

/// # Safety
/// `v` must be a fixnum or a canonical bignum.
pub(crate) unsafe fn integer_i128(v: u64) -> Option<i128> {
    if object::is_fixnum(v) {
        return Some(i128::from(object::fixnum_value(v)));
    }
    unsafe {
        let length = header_length(object::header(v));
        let digits = (object::untag(v) + 8) as *const u64;
        match length {
            1 => Some(i128::from(*digits as i64)),
            2 => Some((i128::from(*digits.add(1) as i64) << 64) | i128::from(*digits)),
            _ => None,
        }
    }
}

/// # Safety
/// `ctx` must be the current context with `safepoint_fp` set.
pub(crate) unsafe fn integer_from_i128(ctx: *mut Context, value: i128) -> u64 {
    if (i128::from(FIXNUM_MIN)..=i128::from(FIXNUM_MAX)).contains(&value) {
        return (value as u64) << 1;
    }
    let length = if i64::try_from(value).is_ok() { 1 } else { 2 };
    unsafe {
        let p = crate::gc::alloc(ctx, 8 + 8 * length, KIND_BIGNUM | (length << LENGTH_SHIFT));
        let digits = (p + 8) as *mut u64;
        *digits = value as u64;
        if length == 2 {
            *digits.add(1) = (value >> 64) as u64;
        }
        p + TAG_GENERAL
    }
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
        if let [digit] = digits {
            return BigInt::from(*digit as i64);
        }
        #[cfg(target_endian = "little")]
        if digits.last().is_some_and(|&digit| (digit as i64) >= 0) {
            let limbs = std::slice::from_raw_parts(digits.as_ptr().cast::<u32>(), n * 2);
            return BigInt::from_slice(num_bigint::Sign::Plus, limbs);
        }
        let negative = digits.last().is_some_and(|&digit| (digit as i64) < 0);
        let mut carry = negative;
        let mut limbs = Vec::with_capacity(n * 2);
        for &digit in digits {
            let magnitude = if negative {
                let (value, overflow) = (!digit).overflowing_add(u64::from(carry));
                carry = overflow;
                value
            } else {
                digit
            };
            limbs.push(magnitude as u32);
            limbs.push((magnitude >> 32) as u32);
        }
        let sign = if negative { num_bigint::Sign::Minus } else { num_bigint::Sign::Plus };
        BigInt::new(sign, limbs)
    }
}

fn signed_word_count(x: &BigInt) -> usize {
    let bits = x.bits();
    let unsigned_words = bits.div_ceil(64);
    let needs_sign_word = bits.is_multiple_of(64)
        && !(x.is_negative() && x.trailing_zeros() == bits.checked_sub(1));
    (unsigned_words + u64::from(needs_sign_word)) as usize
}

fn write_signed_words(x: &BigInt, words: &mut [u64]) {
    let digits = x.iter_u64_digits().chain(std::iter::repeat(0));
    if x.is_negative() {
        let mut carry = true;
        for (word, digit) in words.iter_mut().zip(digits) {
            let (value, overflow) = (!digit).overflowing_add(u64::from(carry));
            *word = value;
            carry = overflow;
        }
    } else {
        for (word, digit) in words.iter_mut().zip(digits) {
            *word = digit;
        }
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
    let n = signed_word_count(x);
    unsafe {
        let p = crate::gc::alloc(ctx, 8 + 8 * n as u64, KIND_BIGNUM | ((n as u64) << LENGTH_SHIFT));
        let words = std::slice::from_raw_parts_mut((p + 8) as *mut u64, n);
        write_signed_words(x, words);
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

fn gcd_batch(x: &BigUint, y: &BigUint, shift: u64) -> Option<[i64; 4]> {
    let x_top = (x >> shift).to_u64().unwrap();
    let y_top = (y >> shift).to_u64().unwrap();
    let (mut x_lo, mut x_hi) = (x_top, x_top + 1);
    let (mut y_lo, mut y_hi) = (y_top, y_top + 1);
    let (mut a, mut b, mut c, mut d) = (1i64, 0i64, 0i64, 1i64);
    const LIMIT: i64 = 1 << 30;

    // Both operands are scaled by the same power of two. Each quotient
    // must agree at the two extremes of their enclosing intervals.
    while y_lo != 0 {
        let quotient = x_lo / y_hi;
        if quotient == 0 || quotient >= LIMIT as u64 || quotient != x_hi / y_lo {
            break;
        }
        let (next_c, next_d) = (a - quotient as i64 * c, b - quotient as i64 * d);
        if next_c.abs().max(next_d.abs()) >= LIMIT {
            break;
        }
        (a, b, c, d) = (c, d, next_c, next_d);
        (x_lo, x_hi, y_lo, y_hi) = (
            y_lo,
            y_hi,
            x_lo - quotient * y_hi,
            x_hi - quotient * y_lo,
        );
    }
    (b != 0).then_some([a, b, c, d])
}

const BATCH_MIN_BITS: u64 = 1024;

pub(crate) fn gcd_ref(x: &BigInt, y: &BigInt) -> BigInt {
    let x = x.magnitude();
    let y = y.magnitude();
    if x.bits().max(y.bits()) < BATCH_MIN_BITS {
        return BigInt::from(x.gcd(y));
    }
    let (large, small) = if x >= y { (x, y) } else { (y, x) };
    if small.is_zero() {
        return BigInt::from(large.clone());
    }
    if large.bits() - small.bits() >= 32 {
        return gcd_magnitudes(small.clone(), large % small);
    }
    gcd_magnitudes(large.clone(), small.clone())
}

fn gcd_magnitudes(mut x: BigUint, mut y: BigUint) -> BigInt {
    if x < y {
        std::mem::swap(&mut x, &mut y);
    }
    while !y.is_zero() && x.bits() >= BATCH_MIN_BITS {
        let bits = x.bits();
        if bits - y.bits() < 32
            && let Some([a, b, c, d]) = gcd_batch(&x, &y, bits - 62)
        {
            // The accumulated matrix maps the operands to two exact,
            // nonnegative Euclidean remainders.
            let left = BigInt::from(x);
            let right = BigInt::from(y);
            x = (&left * a + &right * b).into_parts().1;
            y = (left * c + right * d).into_parts().1;
            continue;
        }
        x %= &y;
        std::mem::swap(&mut x, &mut y);
    }
    BigInt::from(x.gcd(&y))
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
            *(*ctx).values.add(0) = rv;
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
                if x.is_zero() {
                    0
                } else if !y.is_negative() {
                    let s = y.to_usize().unwrap_or(usize::MAX);
                    from_bigint(ctx, &(x << s))
                } else {
                    // Arithmetic shift right rounds toward negative infinity.
                    match (-&y).to_u64() {
                        Some(s) if s <= x.bits() => from_bigint(ctx, &(x >> s as usize)),
                        _ if x.is_negative() => (-1i64 << 1) as u64,
                        _ => 0,
                    }
                }
            }
            OP_GCD => from_bigint(ctx, &gcd_magnitudes(x.into_parts().1, y.into_parts().1)),
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

#[cfg(test)]
mod tests {
    use super::{gcd_magnitudes, gcd_ref, signed_word_count, write_signed_words};
    use num_bigint::BigInt;
    use num_integer::Integer;
    use num_traits::Signed;

    #[test]
    fn integer_gcd_matches_binary_gcd() {
        let mut state = 1u64;
        let mut sample = |words: usize| {
            let mut bytes = Vec::with_capacity(words * 8);
            for _ in 0..words {
                state = state.wrapping_mul(6364136223846793005).wrapping_add(1);
                bytes.extend_from_slice(&state.to_le_bytes());
            }
            BigInt::from_signed_bytes_le(&bytes)
        };
        for words in [1, 15, 16, 17, 32, 128] {
            for _ in 0..16 {
                let x: BigInt = sample(words) * 27;
                let y: BigInt = sample(words) * 27;
                for other in [BigInt::from(0), x.clone(), y.clone(), &y >> 40] {
                    let expected = x.gcd(&other);
                    assert_eq!(gcd_ref(&x, &other), expected);
                    assert_eq!(gcd_ref(&other, &x), expected);
                    assert_eq!(
                        gcd_magnitudes(x.magnitude().clone(), other.magnitude().clone()),
                        expected
                    );
                }
            }
        }
    }

    #[test]
    fn signed_words_match_padded_signed_bytes() {
        for bit in [0usize, 7, 31, 32, 62, 63, 64, 65, 127, 128, 191, 192, 255] {
            let power = BigInt::from(1) << bit;
            for magnitude in [&power - 1, power.clone(), &power + 1] {
                for value in [magnitude.clone(), -magnitude] {
                    let mut expected = value.to_signed_bytes_le();
                    expected.resize(
                        expected.len().next_multiple_of(8),
                        if value.is_negative() { 0xff } else { 0 },
                    );
                    let mut words = vec![0; signed_word_count(&value)];
                    write_signed_words(&value, &mut words);
                    let actual: Vec<_> = words.into_iter().flat_map(u64::to_le_bytes).collect();
                    assert_eq!(actual, expected, "{value}");
                }
            }
        }
    }
}
