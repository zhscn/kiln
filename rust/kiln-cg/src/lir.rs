//! Layout-dependent expansion of backend operations. Semantic checks
//! remain explicit in the Lisp-generated control flow.
use crate::kir::{Expr, Stmt};
use crate::packet::schema::*;
use kiln_rt::object::{FunctionObj, SymbolObj, TAG_CONS, TAG_GENERAL};

fn field_offset(field: u32) -> Result<i32, String> {
    let (offset, tag) = match field {
        FIELD_CONS_CAR => (8, TAG_CONS),
        FIELD_CONS_CDR => (16, TAG_CONS),
        FIELD_SYMBOL_NAME => (core::mem::offset_of!(SymbolObj, name), TAG_GENERAL),
        FIELD_SYMBOL_PACKAGE => (core::mem::offset_of!(SymbolObj, package), TAG_GENERAL),
        FIELD_SYMBOL_FUNCTION => (core::mem::offset_of!(SymbolObj, function), TAG_GENERAL),
        FIELD_SYMBOL_VALUE => (core::mem::offset_of!(SymbolObj, value), TAG_GENERAL),
        FIELD_SYMBOL_TLS_INDEX => (core::mem::offset_of!(SymbolObj, tls_index), TAG_GENERAL),
        FIELD_SYMBOL_PLIST => (core::mem::offset_of!(SymbolObj, plist), TAG_GENERAL),
        FIELD_SYMBOL_SETF_FUNCTION => {
            (core::mem::offset_of!(SymbolObj, setf_function), TAG_GENERAL)
        }
        FIELD_FUNCTION_ENTRY => (core::mem::offset_of!(FunctionObj, entry), TAG_GENERAL),
        _ => return Err(format!("unknown object field {field}")),
    };
    Ok(offset as i32 - tag as i32)
}

pub fn field_load(field: u32, object: Expr) -> Result<Expr, String> {
    Ok(Expr::Load(Box::new(object), field_offset(field)?))
}

pub fn field_store(field: u32, object: Expr, value: Expr) -> Result<Stmt, String> {
    if field == FIELD_FUNCTION_ENTRY {
        return Err("function entry is not an object reference field".into());
    }
    Ok(Stmt::Store(object, field_offset(field)?, value))
}

fn closure_offset(index: i64) -> Result<i32, String> {
    let index = usize::try_from(index).map_err(|_| "invalid closure index")?;
    let offset = index.checked_mul(size_of::<u64>())
        .and_then(|n| n.checked_add(size_of::<FunctionObj>()))
        .and_then(|n| n.checked_sub(TAG_GENERAL as usize))
        .and_then(|n| i32::try_from(n).ok())
        .ok_or("closure index out of range")?;
    Ok(offset)
}

pub fn closure_ref(object: Expr, index: i64) -> Result<Expr, String> {
    Ok(Expr::Load(Box::new(object), closure_offset(index)?))
}

pub fn closure_set(object: Expr, index: i64, value: Expr) -> Result<Stmt, String> {
    Ok(Stmt::Store(object, closure_offset(index)?, value))
}

fn transfer_offset(index: i64) -> Result<i32, String> {
    use kiln_rt::context::{Context, VALUES_MAX};
    let index = usize::try_from(index).map_err(|_| "invalid transfer index")?;
    if index >= VALUES_MAX {
        return Err("transfer index out of range".into());
    }
    Ok((core::mem::offset_of!(Context, values) + index * size_of::<u64>()) as i32)
}

pub fn transfer_ref(index: i64) -> Result<Expr, String> {
    Ok(Expr::Load(Box::new(Expr::Var("ctx".into())), transfer_offset(index)?))
}

pub fn transfer_set(index: i64, value: Expr) -> Result<Stmt, String> {
    Ok(Stmt::Store(Expr::Var("ctx".into()), transfer_offset(index)?, value))
}

/// Materialize the target calling convention after the front end has
/// evaluated the callee and every argument into stable operands.
pub fn invoke(
    v0: String,
    nv: String,
    callee: String,
    args: Vec<Expr>,
    handler: Option<String>,
    loc: Option<crate::kir::Loc>,
) -> Result<Vec<Stmt>, String> {
    use kiln_rt::context::{Context, VALUES_MAX};
    if args.len() > crate::kir::REG_ARGS + VALUES_MAX {
        return Err("invoke: too many arguments".into());
    }
    if args
        .iter()
        .any(|arg| !matches!(arg, Expr::Int(_) | Expr::Var(_)))
    {
        return Err("invoke: arguments must be evaluated into variables or immediates".into());
    }
    let count = args.len();
    let mut statements = Vec::new();
    let mut registers = vec![
        Expr::Var("ctx".into()),
        Expr::Var(callee.clone()),
        Expr::Int(count as i64),
    ];
    for (index, value) in args.into_iter().enumerate() {
        if index < crate::kir::REG_ARGS {
            registers.push(value);
        } else {
            let offset =
                core::mem::offset_of!(Context, values) + (index - crate::kir::REG_ARGS) * 8;
            statements.push(Stmt::Store(Expr::Var("ctx".into()), offset as i32, value));
        }
    }
    statements.push(Stmt::CallLisp {
        v0,
        nv,
        entry: field_load(FIELD_FUNCTION_ENTRY, Expr::Var(callee))?,
        args: registers,
        handler,
        loc,
    });
    Ok(statements)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reference_fields_lower_to_existing_kir() {
        for (field, offset) in [
            (FIELD_CONS_CAR, 7),
            (FIELD_CONS_CDR, 15),
            (FIELD_SYMBOL_FUNCTION, 19),
            (FIELD_FUNCTION_ENTRY, 3),
        ] {
            assert!(matches!(field_load(field, Expr::Var("x".into())).unwrap(),
                             Expr::Load(_, off) if off == offset));
        }
        assert!(field_load(999, Expr::Int(0)).is_err());
        assert!(field_store(FIELD_FUNCTION_ENTRY, Expr::Int(0), Expr::Int(0)).is_err());
    }
}
