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
