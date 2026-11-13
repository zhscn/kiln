use crate::kir::{Expr, Loc, Stmt};

macro_rules! operations {
    ($( $variant:ident => ($name:literal, $module:ident, $code:ident, $args:literal, $values:literal), )*) => {
        #[derive(Clone, Copy, Debug)]
        pub enum NumericOperation { $( $variant, )* }
        impl NumericOperation {
            pub(crate) fn parse(name: &str) -> Option<Self> {
                match name { $( $name => Some(Self::$variant), )* _ => None }
            }
            pub(crate) fn signature(self) -> (&'static str, u64, usize, usize) {
                match self { $( Self::$variant => (
                    if stringify!($module) == "bignum" { "kiln_rt_integer_op" } else { "kiln_rt_number_op" },
                    kiln_rt::$module::$code, $args, $values), )* }
            }
        }
    }
}
// Operator identities select the runtime protocol in Rust, not in the producer.
operations! {
    IntegerAdd => ("integer-add", bignum, OP_ADD, 2, 1),
    IntegerSub => ("integer-sub", bignum, OP_SUB, 2, 1),
    IntegerMul => ("integer-mul", bignum, OP_MUL, 2, 1),
    IntegerTruncate => ("integer-truncate", bignum, OP_TRUNCATE, 2, 2),
    IntegerFloor => ("integer-floor", bignum, OP_FLOOR, 2, 2),
    IntegerCeiling => ("integer-ceiling", bignum, OP_CEILING, 2, 2),
    IntegerRound => ("integer-round", bignum, OP_ROUND, 2, 2),
    IntegerCompare => ("integer-compare", bignum, OP_COMPARE, 2, 1),
    IntegerLogand => ("integer-logand", bignum, OP_LOGAND, 2, 1),
    IntegerLogior => ("integer-logior", bignum, OP_LOGIOR, 2, 1),
    IntegerLogxor => ("integer-logxor", bignum, OP_LOGXOR, 2, 1),
    IntegerAsh => ("integer-ash", bignum, OP_ASH, 2, 1),
    IntegerGcd => ("integer-gcd", bignum, OP_GCD, 2, 1),
    IntegerExpt => ("integer-expt", bignum, OP_EXPT, 2, 1),
    IntegerLength => ("integer-length", bignum, OP_INTEGER_LENGTH, 1, 1),
    NumberAdd => ("number-add", number, OP_ADD, 2, 1),
    NumberSub => ("number-sub", number, OP_SUB, 2, 1),
    NumberMul => ("number-mul", number, OP_MUL, 2, 1),
    NumberDiv => ("number-div", number, OP_DIV, 2, 1),
    NumberTruncate => ("number-truncate", number, OP_TRUNCATE, 2, 2),
    NumberFloor => ("number-floor", number, OP_FLOOR, 2, 2),
    NumberCeiling => ("number-ceiling", number, OP_CEILING, 2, 2),
    NumberRound => ("number-round", number, OP_ROUND, 2, 2),
    NumberCompare => ("number-compare", number, OP_COMPARE, 2, 1),
    NumberEql => ("number-eql", number, OP_EQL, 2, 1),
    ToSingle => ("to-single-float", number, OP_TO_SINGLE, 1, 1),
    ToDouble => ("to-double-float", number, OP_TO_DOUBLE, 1, 1),
    Numerator => ("numerator", number, OP_NUMERATOR, 1, 1),
    Denominator => ("denominator", number, OP_DENOMINATOR, 1, 1),
    Sqrt => ("sqrt", number, OP_SQRT, 1, 1),
    Exp => ("exp", number, OP_EXP, 1, 1),
    Log => ("log", number, OP_LOG, 1, 1),
    Sin => ("sin", number, OP_SIN, 1, 1),
    Cos => ("cos", number, OP_COS, 1, 1),
    Tan => ("tan", number, OP_TAN, 1, 1),
    Atan => ("atan", number, OP_ATAN, 1, 1),
    Rational => ("rational", number, OP_RATIONAL, 1, 1),
    Atan2 => ("atan2", number, OP_ATAN2, 2, 1),
    Expt => ("number-expt", number, OP_EXPT, 2, 1),
}

impl NumericOperation {
    pub(crate) fn lower(
        self,
        primary: String,
        count: String,
        mut args: Vec<Expr>,
        handler: Option<String>,
        loc: Option<Loc>,
    ) -> Result<Vec<Stmt>, String> {
        let (name, code, arity, nvalues) = self.signature();
        if args.len() != arity {
            return Err("wrong numeric operation arity".into());
        }
        if args.len() == 1 {
            args.push(Expr::Int(0));
        }
        args.insert(0, Expr::Int(code as i64));
        args.insert(0, Expr::Var("ctx".into()));
        Ok(vec![
            Stmt::CallRt {
                name: name.into(),
                results: vec![primary],
                args,
                handler,
                loc,
            },
            Stmt::Set(count, Expr::Int(nvalues as i64)),
        ])
    }
}
