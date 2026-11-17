//! Real numbers: the slow path of generic arithmetic.
//!
//! Compiled code open-codes fixnum arithmetic; everything else (bignums,
//! ratios, floats, fixnum overflow) reaches `kiln_rt_number_op` through the
//! kernel's TWO-ARG- functions. Arguments are read into Rust values before
//! anything is allocated, so a GC during allocation cannot invalidate them.
//!
//! Representations:
//! - ratio: [header, numerator, denominator], normalized (denominator > 1,
//!   no common factor); a ratio with denominator 1 is an integer.
//! - single-float: immediate, low byte 0x1b, IEEE bits in bits 32..64.
//! - double-float: [header, IEEE bits].
//!
//! Contagion (CLHS 12.1.4): double > single > rational.

use crate::bignum::{from_bigint, is_bignum, to_bigint};
use crate::context::Context;
use crate::object::{self, KIND_DOUBLE, KIND_MASK, KIND_RATIO, TAG_GENERAL};
use crate::rtfun::{ERR_DIVISION_BY_ZERO, ERR_NOT_NUMBER, error_with};
use num_bigint::BigInt;
use num_integer::Integer;
use num_rational::BigRational;
use num_traits::{FromPrimitive, One, Signed, ToPrimitive, Zero};
use std::cmp::Ordering;

pub const SINGLE_TAG: u64 = 0x1b;

#[derive(Clone, Debug)]
pub enum Num {
    Int(BigInt),
    Ratio(BigRational),
    Single(f32),
    Double(f64),
}

pub fn is_single(v: u64) -> bool {
    v & object::IMMEDIATE_MASK == SINGLE_TAG
}

fn kind_of(v: u64) -> Option<u64> {
    object::is_general(v).then(|| unsafe { object::header(v) } & KIND_MASK)
}

pub fn single_value(v: u64) -> f32 {
    f32::from_bits((v >> 32) as u32)
}

pub fn make_single(x: f32) -> u64 {
    ((x.to_bits() as u64) << 32) | SINGLE_TAG
}

/// # Safety
/// `v` must be a double-float.
pub unsafe fn double_value(v: u64) -> f64 {
    f64::from_bits(unsafe { *((object::untag(v) + 8) as *const u64) })
}

/// Reads the Lisp number `v`, or None if it is not a real.
///
/// # Safety
/// `v` must be a valid Lisp value.
pub unsafe fn read(v: u64) -> Option<Num> {
    unsafe {
        if object::is_fixnum(v) || is_bignum(v) {
            return Some(Num::Int(to_bigint(v)));
        }
        if is_single(v) {
            return Some(Num::Single(single_value(v)));
        }
        match kind_of(v) {
            Some(KIND_RATIO) => {
                let p = object::untag(v);
                let n = to_bigint(*((p + 8) as *const u64));
                let d = to_bigint(*((p + 16) as *const u64));
                Some(Num::Ratio(BigRational::new_raw(n, d)))
            }
            Some(KIND_DOUBLE) => Some(Num::Double(double_value(v))),
            _ => None,
        }
    }
}

/// Makes a Lisp number of `x`, allocating if needed.
///
/// # Safety
/// `ctx` must be the current context with `safepoint_fp` set.
pub unsafe fn write(ctx: *mut Context, x: &Num) -> u64 {
    unsafe {
        match x {
            Num::Int(i) => from_bigint(ctx, i),
            Num::Single(f) => make_single(*f),
            Num::Double(f) => {
                let p = crate::gc::alloc(ctx, 16, KIND_DOUBLE);
                *((p + 8) as *mut u64) = f.to_bits();
                p + TAG_GENERAL
            }
            Num::Ratio(r) => {
                if r.denom().is_one() {
                    return from_bigint(ctx, r.numer());
                }
                // The numerator and denominator may be bignums: keep them
                // in ctx.values as roots while the ratio is allocated.
                let n = from_bigint(ctx, r.numer());
                (*ctx).values[0] = n;
                (*ctx).values_live = 1;
                let d = from_bigint(ctx, r.denom());
                (*ctx).values[1] = d;
                (*ctx).values_live = 2;
                let p = crate::gc::alloc(ctx, 24, KIND_RATIO);
                *((p + 8) as *mut u64) = (*ctx).values[0];
                *((p + 16) as *mut u64) = (*ctx).values[1];
                (*ctx).values_live = 0;
                p + TAG_GENERAL
            }
        }
    }
}

fn to_f64(x: &Num) -> f64 {
    match x {
        Num::Int(i) => i.to_f64().unwrap_or(f64::NAN),
        Num::Ratio(r) => r.to_f64().unwrap_or(f64::NAN),
        Num::Single(f) => *f as f64,
        Num::Double(f) => *f,
    }
}

fn to_f32(x: &Num) -> f32 {
    match x {
        Num::Single(f) => *f,
        _ => to_f64(x) as f32,
    }
}

fn to_rational(x: &Num) -> BigRational {
    match x {
        Num::Int(i) => BigRational::from_integer(i.clone()),
        Num::Ratio(r) => r.clone(),
        Num::Single(f) => BigRational::from_float(*f).unwrap_or_default(),
        Num::Double(f) => BigRational::from_float(*f).unwrap_or_default(),
    }
}

/// The float format results take, if any (CLHS 12.1.4.1).
#[derive(PartialEq, Eq, PartialOrd, Ord, Clone, Copy)]
enum Format {
    Rational,
    Single,
    Double,
}

fn format_of(x: &Num) -> Format {
    match x {
        Num::Int(_) | Num::Ratio(_) => Format::Rational,
        Num::Single(_) => Format::Single,
        Num::Double(_) => Format::Double,
    }
}

fn normalize(r: BigRational) -> Num {
    if r.denom().is_one() {
        Num::Int(r.to_integer())
    } else {
        Num::Ratio(r)
    }
}

fn arith(op: u64, x: &Num, y: &Num) -> Num {
    match format_of(x).max(format_of(y)) {
        Format::Double => {
            let (a, b) = (to_f64(x), to_f64(y));
            Num::Double(match op {
                OP_ADD => a + b,
                OP_SUB => a - b,
                OP_MUL => a * b,
                _ => a / b,
            })
        }
        Format::Single => {
            let (a, b) = (to_f32(x), to_f32(y));
            Num::Single(match op {
                OP_ADD => a + b,
                OP_SUB => a - b,
                OP_MUL => a * b,
                _ => a / b,
            })
        }
        Format::Rational => {
            if let (Num::Int(a), Num::Int(b)) = (x, y)
                && op != OP_DIV
            {
                return Num::Int(match op {
                    OP_ADD => a + b,
                    OP_SUB => a - b,
                    _ => a * b,
                });
            }
            let (a, b) = (to_rational(x), to_rational(y));
            normalize(match op {
                OP_ADD => a + b,
                OP_SUB => a - b,
                OP_MUL => a * b,
                _ => a / b,
            })
        }
    }
}

/// Finite mixed comparisons stay exact; NaN is unordered and infinities
/// must not pass through conversion to a rational.
fn compare(x: &Num, y: &Num) -> Option<Ordering> {
    fn non_finite(x: &Num) -> Option<f64> {
        let f = match x {
            Num::Single(f) => *f as f64,
            Num::Double(f) => *f,
            _ => return None,
        };
        (!f.is_finite()).then_some(f)
    }
    match (non_finite(x), non_finite(y)) {
        (Some(a), _) if a.is_nan() => None,
        (_, Some(b)) if b.is_nan() => None,
        (Some(a), Some(b)) => a.partial_cmp(&b),
        (Some(a), None) => Some(if a.is_sign_negative() {
            Ordering::Less
        } else {
            Ordering::Greater
        }),
        (None, Some(b)) => Some(if b.is_sign_negative() {
            Ordering::Greater
        } else {
            Ordering::Less
        }),
        _ => Some(match (x, y) {
            (Num::Int(a), Num::Int(b)) => a.cmp(b),
            (Num::Single(a), Num::Single(b)) => a.partial_cmp(b).unwrap(),
            (Num::Double(a), Num::Double(b)) => a.partial_cmp(b).unwrap(),
            _ => to_rational(x).cmp(&to_rational(y)),
        }),
    }
}

fn is_zero(x: &Num) -> bool {
    match x {
        Num::Int(i) => i.is_zero(),
        Num::Ratio(r) => r.is_zero(),
        Num::Single(f) => *f == 0.0,
        Num::Double(f) => *f == 0.0,
    }
}

/// Quotient (an integer) and remainder of a division with the rounding
/// of OP (TRUNCATE, FLOOR, CEILING or ROUND).
fn divide(op: u64, x: &Num, y: &Num) -> (BigInt, Num) {
    if let (Num::Int(a), Num::Int(b)) = (x, y) {
        // Reducing a/b first computes a GCD that integer division never needs.
        let (mut q, mut r) = a.div_rem(b);
        if !r.is_zero() {
            let same_sign = r.is_negative() == b.is_negative();
            let adjustment = match op {
                OP_FLOOR if !same_sign => -1,
                OP_CEILING if same_sign => 1,
                OP_ROUND => {
                    let twice_remainder = r.abs() << 1;
                    if twice_remainder > b.abs()
                        || (twice_remainder == b.abs() && q.is_odd())
                    {
                        if same_sign { 1 } else { -1 }
                    } else {
                        0
                    }
                }
                _ => 0,
            };
            q += adjustment;
            r -= b * adjustment;
        }
        return (q, Num::Int(r));
    }
    let format = format_of(x).max(format_of(y));
    let q = if format == Format::Rational {
        let r = to_rational(x) / to_rational(y);
        match op {
            OP_TRUNCATE => r.trunc().to_integer(),
            OP_FLOOR => r.floor().to_integer(),
            OP_CEILING => r.ceil().to_integer(),
            _ => {
                // Round to nearest, ties to even.
                let f = r.floor();
                let diff = &r - &f;
                let half = BigRational::new(BigInt::one(), BigInt::from(2));
                let fi = f.to_integer();
                match diff.cmp(&half) {
                    Ordering::Less => fi,
                    Ordering::Greater => fi + 1,
                    Ordering::Equal => {
                        if fi.is_even() { fi } else { fi + 1 }
                    }
                }
            }
        }
    } else {
        let r = to_f64(x) / to_f64(y);
        let q = match op {
            OP_TRUNCATE => r.trunc(),
            OP_FLOOR => r.floor(),
            OP_CEILING => r.ceil(),
            _ => r.round_ties_even(),
        };
        BigInt::from_f64(q).unwrap_or_default()
    };
    let qn = Num::Int(q.clone());
    let rem = arith(OP_SUB, x, &arith(OP_MUL, &qn, y));
    (q, rem)
}

pub const OP_ADD: u64 = 0;
pub const OP_SUB: u64 = 1;
pub const OP_MUL: u64 = 2;
pub const OP_DIV: u64 = 3;
pub const OP_TRUNCATE: u64 = 4;
pub const OP_FLOOR: u64 = 5;
pub const OP_CEILING: u64 = 6;
pub const OP_ROUND: u64 = 7;
pub const OP_COMPARE: u64 = 8;
pub const OP_EQL: u64 = 9;
/// Unary from here: `b` is ignored.
pub const OP_TO_SINGLE: u64 = 10;
pub const OP_TO_DOUBLE: u64 = 11;
pub const OP_NUMERATOR: u64 = 12;
pub const OP_DENOMINATOR: u64 = 13;
pub const OP_SQRT: u64 = 14;
pub const OP_EXP: u64 = 15;
pub const OP_LOG: u64 = 16;
pub const OP_SIN: u64 = 17;
pub const OP_COS: u64 = 18;
pub const OP_TAN: u64 = 19;
pub const OP_ATAN: u64 = 20;
pub const OP_RATIONAL: u64 = 21;
/// Binary again.
pub const OP_ATAN2: u64 = 22;
pub const OP_EXPT: u64 = 23;
pub const OP_HYPOT: u64 = 24;
pub const OP_SINH: u64 = 25;
pub const OP_COSH: u64 = 26;
pub const OP_TANH: u64 = 27;
pub const OP_ATANH: u64 = 28;

/// Applies a float function, keeping the argument's float format
/// (rationals give single-floats, CLHS 12.1.4.1.1).
fn float_fn(x: &Num, f: fn(f64) -> f64) -> Num {
    if format_of(x) == Format::Double {
        Num::Double(f(to_f64(x)))
    } else {
        Num::Single(f(to_f64(x)) as f32)
    }
}

#[link(name = "m")]
unsafe extern "C" {
    #[link_name = "atanh"]
    fn libm_atanh(x: f64) -> f64;
}

fn real_atanh(x: f64) -> f64 {
    // Rust's atanh expands log1p(2*x/(1-x)); near -1, that ratio
    // rounds close to -1 and loses digits before log1p sees it.
    // libm reduces by magnitude and preserves the odd symmetry.
    unsafe { libm_atanh(x) }
}

fn hypot(x: &Num, y: &Num) -> Num {
    if format_of(x).max(format_of(y)) == Format::Double {
        Num::Double(to_f64(x).hypot(to_f64(y)))
    } else {
        Num::Single(to_f32(x).hypot(to_f32(y)))
    }
}

fn expt(x: &Num, y: &Num) -> Num {
    match y {
        Num::Int(e) if format_of(x) == Format::Rational || e.bits() < 64 => {
            // Exact for rationals; repeated squaring keeps floats close.
            let (mut base, mut n) = (x.clone(), e.abs());
            let mut acc = Num::Int(BigInt::one());
            while !n.is_zero() {
                if n.is_odd() {
                    acc = arith(OP_MUL, &acc, &base);
                }
                base = arith(OP_MUL, &base, &base);
                n >>= 1;
            }
            if e.is_negative() { arith(OP_DIV, &Num::Int(BigInt::one()), &acc) } else { acc }
        }
        _ => {
            let r = to_f64(x).powf(to_f64(y));
            if format_of(x).max(format_of(y)) == Format::Double {
                Num::Double(r)
            } else {
                Num::Single(r as f32)
            }
        }
    }
}

unsafe fn number_arg(ctx: *mut Context, v: u64) -> Num {
    match unsafe { read(v) } {
        Some(n) => n,
        None => unsafe { error_with(ctx, ERR_NOT_NUMBER, v) },
    }
}

/// Number operation `op` on the reals `a` and `b`. Division operators
/// return the quotient and store the remainder in `ctx.values[0]` (two
/// values). COMPARE returns -1, 0, 1 or 2 (unordered), and EQL T or NIL. Called through a
/// trampoline; `fp` is its frame pointer.
///
/// # Safety
/// Must be called by compiled code with a valid context.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_number_op(ctx: *mut Context, op: u64, a: u64, b: u64, fp: usize) -> u64 {
    unsafe {
        (*ctx).safepoint_fp = fp;
        if op == OP_EQL {
            // Same type and same value; floats by their bits.
            return match (read(a), read(b)) {
                (Some(Num::Int(x)), Some(Num::Int(y))) if x == y => object::t(),
                (Some(Num::Ratio(x)), Some(Num::Ratio(y))) if x == y => object::t(),
                (Some(Num::Double(x)), Some(Num::Double(y))) if x.to_bits() == y.to_bits() => object::t(),
                _ => object::nil(),
            };
        }
        let x = number_arg(ctx, a);
        let unary = (OP_TO_SINGLE..=OP_RATIONAL).contains(&op)
            || (OP_SINH..=OP_ATANH).contains(&op);
        let y = if unary { Num::Int(BigInt::zero()) } else { number_arg(ctx, b) };
        if (op == OP_DIV || (OP_TRUNCATE..=OP_ROUND).contains(&op)) && is_zero(&y) {
            error_with(ctx, ERR_DIVISION_BY_ZERO, a);
        }
        let result = match op {
            OP_ADD | OP_SUB | OP_MUL | OP_DIV => arith(op, &x, &y),
            OP_TRUNCATE..=OP_ROUND => {
                let (q, r) = divide(op, &x, &y);
                // Allocate the remainder first and keep it as a root while
                // the quotient is allocated.
                let rv = write(ctx, &r);
                (*ctx).values[2] = rv;
                (*ctx).values_live = 3;
                let qv = from_bigint(ctx, &q);
                (*ctx).values[0] = (*ctx).values[2];
                (*ctx).values_live = 0;
                return qv;
            }
            OP_COMPARE => return ((compare(&x, &y).map_or(2, |order| order as i64)) << 1) as u64,
            OP_TO_SINGLE => Num::Single(to_f32(&x)),
            OP_TO_DOUBLE => Num::Double(to_f64(&x)),
            OP_NUMERATOR => match &x {
                Num::Ratio(r) => Num::Int(r.numer().clone()),
                _ => x.clone(),
            },
            OP_DENOMINATOR => match &x {
                Num::Ratio(r) => Num::Int(r.denom().clone()),
                _ => Num::Int(BigInt::one()),
            },
            OP_SQRT => float_fn(&x, f64::sqrt),
            OP_EXP => float_fn(&x, f64::exp),
            OP_LOG => float_fn(&x, f64::ln),
            OP_SIN => float_fn(&x, f64::sin),
            OP_COS => float_fn(&x, f64::cos),
            OP_TAN => float_fn(&x, f64::tan),
            OP_ATAN => float_fn(&x, f64::atan),
            OP_RATIONAL => normalize(to_rational(&x)),
            OP_ATAN2 => {
                let r = to_f64(&x).atan2(to_f64(&y));
                if format_of(&x).max(format_of(&y)) == Format::Double {
                    Num::Double(r)
                } else {
                    Num::Single(r as f32)
                }
            }
            OP_EXPT => expt(&x, &y),
            OP_HYPOT => hypot(&x, &y),
            OP_SINH => float_fn(&x, f64::sinh),
            OP_COSH => float_fn(&x, f64::cosh),
            OP_TANH => float_fn(&x, f64::tanh),
            OP_ATANH => float_fn(&x, real_atanh),
            _ => crate::rtfun::error_exit("kiln_rt_number_op: unknown operation"),
        };
        write(ctx, &result)
    }
}

/// Prints a float the way the CL printer does with
/// *READ-DEFAULT-FLOAT-FORMAT* = SINGLE-FLOAT: shortest digits that read
/// back; fixed notation for 1e-3 <= |x| < 1e7, else exponent notation;
/// doubles marked with d.
pub fn write_float(out: &mut String, x: f64, double: bool, shortest: String, exp_form: String) {
    use std::fmt::Write;
    if x.is_nan() {
        out.push_str(if double { "#<DOUBLE-FLOAT NaN>" } else { "#<SINGLE-FLOAT NaN>" });
        return;
    }
    if x.is_infinite() {
        let _ = write!(
            out,
            "#.{}{}",
            if double { "DOUBLE-FLOAT-" } else { "SINGLE-FLOAT-" },
            if x > 0.0 { "POSITIVE-INFINITY" } else { "NEGATIVE-INFINITY" }
        );
        return;
    }
    let ax = x.abs();
    if ax == 0.0 || (1e-3..1e7).contains(&ax) {
        out.push_str(&shortest);
        if !shortest.contains('.') {
            out.push_str(".0");
        }
        if double {
            out.push_str("d0");
        }
    } else {
        // exp_form looks like "1.5e-5" or "1e20".
        let (mantissa, exponent) = exp_form.split_once('e').unwrap_or((&exp_form, "0"));
        out.push_str(mantissa);
        if !mantissa.contains('.') {
            out.push_str(".0");
        }
        out.push(if double { 'd' } else { 'e' });
        out.push_str(exponent);
    }
}

/// # Safety
/// `v` must be a ratio, single-float or double-float.
pub unsafe fn write_number(out: &mut String, v: u64) {
    use std::fmt::Write;
    unsafe {
        match read(v) {
            Some(Num::Ratio(r)) => {
                let _ = write!(out, "{}/{}", r.numer(), r.denom());
            }
            Some(Num::Single(f)) => write_float(out, f as f64, false, format!("{f}"), format!("{f:e}")),
            Some(Num::Double(f)) => write_float(out, f, true, format!("{f}"), format!("{f:e}")),
            Some(Num::Int(i)) => {
                let _ = write!(out, "{i}");
            }
            None => out.push_str("#<NOT A NUMBER>"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_finite_comparison_never_coerces_to_rational_zero() {
        let finite = [
            Num::Int(BigInt::one() << 2000),
            Num::Ratio(BigRational::new(1.into(), 3.into())),
            Num::Single(0.0),
            Num::Double(-1.0),
        ];
        for x in &finite {
            for infinity in [Num::Single(f32::INFINITY), Num::Double(f64::INFINITY)] {
                assert_eq!(compare(x, &infinity), Some(Ordering::Less));
                assert_eq!(compare(&infinity, x), Some(Ordering::Greater));
            }
            assert_eq!(
                compare(x, &Num::Double(f64::NEG_INFINITY)),
                Some(Ordering::Greater)
            );
            for nan in [Num::Single(f32::NAN), Num::Double(f64::NAN)] {
                assert_eq!(compare(x, &nan), None);
                assert_eq!(compare(&nan, x), None);
            }
        }
        assert_eq!(
            compare(&Num::Single(f32::INFINITY), &Num::Double(f64::INFINITY)),
            Some(Ordering::Equal)
        );
        assert_eq!(
            compare(&Num::Single(f32::NEG_INFINITY), &Num::Double(f64::INFINITY)),
            Some(Ordering::Less)
        );
        assert_eq!(
            compare(&Num::Double(f64::NAN), &Num::Double(f64::NAN)),
            None
        );
    }

    #[test]
    fn inverse_hyperbolic_tangent_keeps_signed_accuracy() {
        for (x, reference) in [
            (0.9827284275322304, 2.371583614415883),
            (0.03531254506018124, 0.035327234015308566),
            (0.2902613110736827, 0.29885159252037635),
        ] {
            assert_eq!(real_atanh(x), reference);
            assert_eq!(real_atanh(-x), -reference);
        }
        assert_eq!(real_atanh(-0.0).to_bits(), (-0.0f64).to_bits());
        assert_eq!(real_atanh(f64::from_bits(1)).to_bits(), 1);
    }

    #[test]
    fn integer_division_obeys_rounding_and_reconstruction() {
        for a in -37i64..=37 {
            for b in (-13i64..=13).filter(|b| *b != 0) {
                for op in [OP_TRUNCATE, OP_FLOOR, OP_CEILING, OP_ROUND] {
                    let (q, r) = divide(op, &Num::Int(a.into()), &Num::Int(b.into()));
                    let Num::Int(r) = r else { panic!("integer remainder expected") };
                    assert_eq!(&q * b + &r, BigInt::from(a));
                    let ratio = a as f64 / b as f64;
                    let reference = match op {
                        OP_TRUNCATE => ratio.trunc(),
                        OP_FLOOR => ratio.floor(),
                        OP_CEILING => ratio.ceil(),
                        _ => ratio.round_ties_even(),
                    };
                    assert_eq!(q, BigInt::from(reference as i64));
                }
            }
        }
        let divisor = (BigInt::one() << 8192) + 17;
        let quotient = (BigInt::one() << 4096) + 3;
        let numerator = &divisor * &quotient + 7;
        let (q, r) = divide(OP_TRUNCATE, &Num::Int(numerator), &Num::Int(divisor));
        assert_eq!(q, quotient);
        assert!(matches!(r, Num::Int(r) if r == BigInt::from(7)));
    }

    #[test]
    fn finite_mixed_comparison_retains_exact_precision() {
        assert_eq!(
            compare(
                &Num::Int((BigInt::one() << 53) + 1),
                &Num::Double(9007199254740992.0)
            ),
            Some(Ordering::Greater)
        );
        assert_eq!(
            compare(
                &Num::Ratio(BigRational::new(1.into(), 10.into())),
                &Num::Double(0.1)
            ),
            Some(Ordering::Less)
        );
    }
}
