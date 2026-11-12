//! Layout-dependent expansion of backend operations. Semantic checks
//! remain explicit in the Lisp-generated control flow.
use crate::kir::{Expr, Stmt};
use crate::packet::schema::*;
use kiln_rt::object::{FunctionObj, SymbolObj, TAG_CONS, TAG_GENERAL};

pub fn static_object_tag(kind: &str) -> Result<i64, String> {
    match kind {
        "cons" => Ok(TAG_CONS as i64),
        "general" => Ok(TAG_GENERAL as i64),
        _ => Err(format!("unknown static object representation {kind}")),
    }
}

pub fn static_field_root_index(field: u32) -> Result<u32, String> {
    match field {
        FIELD_CONS_CAR | FIELD_CONS_CDR => Ok(((field_offset(field)? + TAG_CONS as i32) / size_of::<u64>() as i32) as u32),
        _ => symbol_root_index(field),
    }
}

pub fn test_class(class: u32, object: Expr) -> Result<Expr, String> {
    use crate::kir::{BinOp, CmpOp};
    use kiln_rt::object::{CHARACTER_TAG, FIXNUM_MASK, IMMEDIATE_MASK, TAG_MASK};
    let (mask, tag) = match class {
        CLASS_FIXNUM => (FIXNUM_MASK, 0),
        CLASS_CONS => (TAG_MASK, TAG_CONS),
        CLASS_CHARACTER => (IMMEDIATE_MASK, CHARACTER_TAG),
        CLASS_GENERAL => (TAG_MASK, TAG_GENERAL),
        _ => return Err(format!("unknown representation class {class}")),
    };
    Ok(Expr::Cmp(
        CmpOp::Eq,
        Box::new(Expr::Bin(BinOp::And, Box::new(object), Box::new(Expr::Int(mask as i64)))),
        Box::new(Expr::Int(tag as i64)),
    ))
}

/// The caller must guard this operation with a general-object test.
pub fn test_header_class(class: u32, object: Expr) -> Result<Expr, String> {
    use crate::kir::{BinOp, CmpOp};
    use kiln_rt::object::*;
    let (mask, kind) = match class {
        CLASS_SYMBOL => (KIND_MASK, KIND_SYMBOL),
        CLASS_FUNCTION => (KIND_MASK ^ (KIND_FUNCTION ^ KIND_FUNCALLABLE_INSTANCE), KIND_FUNCTION),
        CLASS_SIMPLE_VECTOR => (KIND_MASK, KIND_SIMPLE_VECTOR),
        CLASS_STRING => (KIND_MASK, KIND_STRING),
        CLASS_BIGNUM => (KIND_MASK, KIND_BIGNUM),
        CLASS_RATIO => (KIND_MASK, KIND_RATIO),
        CLASS_DOUBLE => (KIND_MASK, KIND_DOUBLE),
        CLASS_INSTANCE => (KIND_MASK, KIND_INSTANCE),
        CLASS_FUNCALLABLE_INSTANCE => (KIND_MASK, KIND_FUNCALLABLE_INSTANCE),
        CLASS_COMPLEX => (KIND_MASK, KIND_COMPLEX),
        CLASS_STRUCTURE_INSTANCE => (KIND_MASK, KIND_STRUCTURE_INSTANCE),
        _ => return Err(format!("unknown header class {class}")),
    };
    Ok(Expr::Cmp(CmpOp::Eq,
        Box::new(Expr::Bin(BinOp::And,
            Box::new(Expr::Load(Box::new(object), -(TAG_GENERAL as i32))),
            Box::new(Expr::Int(mask as i64)))),
        Box::new(Expr::Int(kind as i64))))
}

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
        FIELD_DOUBLE_BITS | FIELD_COMPLEX_REAL => (size_of::<u64>(), TAG_GENERAL),
        FIELD_COMPLEX_IMAG => (2 * size_of::<u64>(), TAG_GENERAL),
        _ => return Err(format!("unknown object field {field}")),
    };
    Ok(offset as i32 - tag as i32)
}

pub fn field_load(field: u32, object: Expr) -> Result<Expr, String> {
    Ok(Expr::Load(Box::new(object), field_offset(field)?))
}

pub fn field_store(field: u32, object: Expr, value: Expr) -> Result<Stmt, String> {
    if matches!(field, FIELD_FUNCTION_ENTRY | FIELD_DOUBLE_BITS) {
        return Err("field is not an object reference field".into());
    }
    Ok(Stmt::Store(object, field_offset(field)?, value))
}

pub fn symbol_root_index(field: u32) -> Result<u32, String> {
    let offset = match field {
        FIELD_SYMBOL_PACKAGE => core::mem::offset_of!(SymbolObj, package),
        FIELD_SYMBOL_FUNCTION => core::mem::offset_of!(SymbolObj, function),
        FIELD_SYMBOL_VALUE => core::mem::offset_of!(SymbolObj, value),
        FIELD_SYMBOL_TLS_INDEX => core::mem::offset_of!(SymbolObj, tls_index),
        FIELD_SYMBOL_PLIST => core::mem::offset_of!(SymbolObj, plist),
        FIELD_SYMBOL_SETF_FUNCTION => core::mem::offset_of!(SymbolObj, setf_function),
        _ => return Err(format!("invalid static symbol root field {field}")),
    };
    Ok((offset / size_of::<u64>()) as u32)
}

pub fn fixnum_untag(value: Expr) -> Expr {
    Expr::Shift(crate::kir::ShiftOp::Sar, Box::new(value), 1)
}

pub fn tls_address(index: Expr) -> Expr {
    use crate::kir::{BinOp, ShiftOp};
    let table = Expr::Load(Box::new(Expr::Var("ctx".into())), core::mem::offset_of!(kiln_rt::context::Context, tls) as i32);
    Expr::Bin(BinOp::Add, Box::new(table), Box::new(Expr::Shift(ShiftOp::Shl, Box::new(index), 2)))
}

pub fn no_tls_value(value: Expr) -> Expr {
    Expr::Cmp(crate::kir::CmpOp::Eq, Box::new(value), Box::new(Expr::Int(kiln_rt::special::NO_TLS_VALUE as i64)))
}

pub fn poll_test(kind: &str) -> Result<Expr, String> {
    use kiln_rt::context::Context;
    let context = || Expr::Var("ctx".into());
    match kind {
        "entry" => Ok(Expr::Cmp(crate::kir::CmpOp::Lt, Box::new(Expr::Fp),
            Box::new(Expr::Load(Box::new(context()), core::mem::offset_of!(Context, stack_limit) as i32)))),
        "loop" => Ok(Expr::Load(Box::new(context()), core::mem::offset_of!(Context, poll_flag) as i32)),
        _ => Err(format!("unknown poll test {kind}")),
    }
}

pub fn tls_read(symbol: Expr) -> Result<Expr, String> {
    Ok(Expr::Load(Box::new(tls_address(field_load(FIELD_SYMBOL_TLS_INDEX, symbol)?)), 0))
}

pub fn tls_write(symbol: Expr, value: Expr) -> Result<Stmt, String> {
    Ok(Stmt::Store(tls_address(field_load(FIELD_SYMBOL_TLS_INDEX, symbol)?), 0, value))
}

#[allow(clippy::type_complexity)]
pub fn ensure_tls_index(name: &str, block: String, mut preceding: Vec<Stmt>, result: String,
                        symbol: String, runtime: String)
    -> Result<(Vec<crate::kir::Block>, String), String> {
    use crate::kir::{Block, CmpOp};
    let assign = format!("{name}_assign");
    let done = format!("{name}_done");
    preceding.push(Stmt::Set(result.clone(), field_load(FIELD_SYMBOL_TLS_INDEX, Expr::Var(symbol.clone()))?));
    preceding.push(Stmt::Br(Expr::Cmp(CmpOp::Eq, Box::new(Expr::Var(result.clone())), Box::new(Expr::Int(0))), assign.clone(), done.clone()));
    Ok((vec![
        Block { name: block, stmts: preceding },
        Block { name: assign, stmts: vec![
            Stmt::CallRt { name: runtime, results: vec![result], args: vec![Expr::Var("ctx".into()), Expr::Var(symbol)], handler: None, loc: None },
            Stmt::Jump(done.clone()),
        ] },
    ], done))
}

#[allow(clippy::type_complexity, clippy::too_many_arguments)]
pub fn special_access(name: &str, block: String, mut preceding: Vec<Stmt>, symbol: String,
                      result: Option<String>, value: Option<Expr>)
    -> Result<(Vec<(String, crate::kir::VarKind)>, Vec<crate::kir::Block>, String), String> {
    use crate::kir::{Block, VarKind};
    let addr = format!("{name}_tls");
    let global = format!("{name}_global");
    let done = format!("{name}_done");
    let var = |name: &str| Expr::Var(name.to_string());
    preceding.push(Stmt::Set(addr.clone(), tls_address(field_load(FIELD_SYMBOL_TLS_INDEX, var(&symbol))?)));
    let mut blocks = Vec::new();
    if let Some(result) = result {
        preceding.push(Stmt::Set(result.clone(), Expr::Load(Box::new(var(&addr)), 0)));
        preceding.push(Stmt::Br(no_tls_value(var(&result)), global.clone(), done.clone()));
        blocks.push(Block { name: block, stmts: preceding });
        blocks.push(Block { name: global, stmts: vec![
            Stmt::Set(result, field_load(FIELD_SYMBOL_VALUE, var(&symbol))?), Stmt::Jump(done.clone()),
        ] });
    } else if let Some(value) = value {
        let local = format!("{name}_local");
        preceding.push(Stmt::Br(no_tls_value(Expr::Load(Box::new(var(&addr)), 0)), global.clone(), local.clone()));
        blocks.push(Block { name: block, stmts: preceding });
        blocks.push(Block { name: global, stmts: vec![field_store(FIELD_SYMBOL_VALUE, var(&symbol), value.clone())?, Stmt::Jump(done.clone())] });
        blocks.push(Block { name: local, stmts: vec![Stmt::Store(var(&addr), 0, value), Stmt::Jump(done.clone())] });
    } else {
        return Err("special access requires a result or value".into());
    }
    Ok((vec![(addr, VarKind::Raw)], blocks, done))
}

pub fn fixnum_tag(value: Expr) -> Expr {
    Expr::Shift(crate::kir::ShiftOp::Shl, Box::new(value), 1)
}

pub fn vector_length(object: Expr) -> Expr {
    use crate::kir::{BinOp, ShiftOp};
    use kiln_rt::object::{LENGTH_MASK, LENGTH_SHIFT};
    Expr::Bin(BinOp::And,
        Box::new(Expr::Shift(ShiftOp::Shr,
            Box::new(Expr::Load(Box::new(object), -(TAG_GENERAL as i32))), LENGTH_SHIFT as i64)),
        Box::new(Expr::Int(LENGTH_MASK as i64)))
}

pub fn invalid_vector_length(value: Expr) -> Expr {
    invalid_length(value, kiln_rt::object::LENGTH_MASK)
}

pub fn invalid_rack_length(value: Expr) -> Expr {
    invalid_length(value, kiln_rt::object::LENGTH_MASK - 1)
}

fn invalid_length(value: Expr, max: u64) -> Expr {
    use crate::kir::{BinOp, CmpOp};
    use kiln_rt::object::FIXNUM_MASK;
    Expr::Bin(BinOp::Or,
        Box::new(Expr::Bin(BinOp::And, Box::new(value.clone()), Box::new(Expr::Int(FIXNUM_MASK as i64)))),
        Box::new(Expr::Bin(BinOp::Or,
            Box::new(Expr::Cmp(CmpOp::Lt, Box::new(value.clone()), Box::new(Expr::Int(0)))),
            Box::new(Expr::Cmp(CmpOp::Gt, Box::new(value), Box::new(Expr::Int((max << 1) as i64)))))))
}

fn vector_element_address(object: Expr, index: Expr) -> Expr {
    use crate::kir::{BinOp, ShiftOp};
    Expr::Bin(BinOp::Add, Box::new(object),
        Box::new(Expr::Shift(ShiftOp::Shl, Box::new(index), 3)))
}

pub fn vector_ref(object: Expr, index: Expr) -> Expr {
    Expr::Load(Box::new(vector_element_address(object, index)), size_of::<u64>() as i32 - TAG_GENERAL as i32)
}

pub fn vector_set(object: Expr, index: Expr, value: Expr) -> Stmt {
    Stmt::Store(vector_element_address(object, index), size_of::<u64>() as i32 - TAG_GENERAL as i32, value)
}

pub fn character_untag(value: Expr) -> Expr {
    Expr::Shift(crate::kir::ShiftOp::Shr, Box::new(value), kiln_rt::object::CHARACTER_SHIFT as i64)
}

pub fn character_tag(code: Expr) -> Expr {
    use crate::kir::{BinOp, ShiftOp};
    Expr::Bin(BinOp::Or,
        Box::new(Expr::Shift(ShiftOp::Shl, Box::new(code), kiln_rt::object::CHARACTER_SHIFT as i64)),
        Box::new(Expr::Int(kiln_rt::object::CHARACTER_TAG as i64)))
}

fn string_element_address(object: Expr, index: Expr) -> Expr {
    use crate::kir::{BinOp, ShiftOp};
    Expr::Bin(BinOp::Add, Box::new(object), Box::new(Expr::Shift(ShiftOp::Shl, Box::new(index), 2)))
}

pub fn string_ref(object: Expr, index: Expr) -> Expr {
    character_tag(Expr::Load32(Box::new(string_element_address(object, index)), size_of::<u64>() as i32 - TAG_GENERAL as i32))
}

pub fn string_set(object: Expr, index: Expr, value: Expr) -> Stmt {
    Stmt::Store32(string_element_address(object, index), size_of::<u64>() as i32 - TAG_GENERAL as i32, character_untag(value))
}

fn instance_rack_address(object: Expr) -> Result<Expr, String> {
    use crate::kir::BinOp;
    let is_standard = test_header_class(CLASS_INSTANCE, object.clone())?;
    let offset = Expr::Select(Box::new(is_standard), Box::new(Expr::Int(0)), Box::new(Expr::Int(size_of::<u64>() as i64)));
    Ok(Expr::Bin(BinOp::Add, Box::new(object), Box::new(offset)))
}

pub fn instance_rack(object: Expr) -> Result<Expr, String> {
    Ok(Expr::Load(Box::new(instance_rack_address(object)?), size_of::<u64>() as i32 - TAG_GENERAL as i32))
}

pub fn set_instance_rack(object: Expr, value: Expr) -> Result<Stmt, String> {
    Ok(Stmt::Store(instance_rack_address(object)?, size_of::<u64>() as i32 - TAG_GENERAL as i32, value))
}

fn indexed_object_address(object: Expr, index: Expr) -> Expr {
    Expr::Bin(crate::kir::BinOp::Add, Box::new(object),
        Box::new(Expr::Shift(crate::kir::ShiftOp::Shl, Box::new(index), 3)))
}

pub fn instance_class(object: Expr) -> Result<Expr, String> {
    Ok(Expr::Load(Box::new(instance_rack(object)?), size_of::<u64>() as i32 - TAG_GENERAL as i32))
}

pub fn instance_slot(object: Expr, index: Expr) -> Result<Expr, String> {
    Ok(Expr::Load(Box::new(indexed_object_address(instance_rack(object)?, index)), (4 * size_of::<u64>()) as i32 - TAG_GENERAL as i32))
}

pub fn set_instance_slot(object: Expr, index: Expr, value: Expr) -> Result<Stmt, String> {
    Ok(Stmt::Store(indexed_object_address(instance_rack(object)?, index), (4 * size_of::<u64>()) as i32 - TAG_GENERAL as i32, value))
}

pub fn structure_layout(object: Expr) -> Expr {
    Expr::Load(Box::new(object), size_of::<u64>() as i32 - TAG_GENERAL as i32)
}

pub fn structure_allocation_layout(count: &Expr) -> Result<(Expr, Expr), String> {
    use crate::kir::{BinOp, ShiftOp};
    use kiln_rt::object::{KIND_STRUCTURE_INSTANCE, LENGTH_MASK, LENGTH_SHIFT};
    if let Expr::Int(n) = count {
        if *n < 0 || *n as u64 > LENGTH_MASK { return Err("structure slot count out of range".into()); }
        return Ok((Expr::Int(2 * size_of::<u64>() as i64 + n * size_of::<u64>() as i64),
                   Expr::Int(((*n as u64) << LENGTH_SHIFT | KIND_STRUCTURE_INSTANCE) as i64)));
    }
    Ok((Expr::Bin(BinOp::Add, Box::new(Expr::Int((2 * size_of::<u64>()) as i64)),
                  Box::new(Expr::Shift(ShiftOp::Shl, Box::new(count.clone()), 3))),
        Expr::Bin(BinOp::Or, Box::new(Expr::Int(KIND_STRUCTURE_INSTANCE as i64)),
                  Box::new(Expr::Shift(ShiftOp::Shl, Box::new(count.clone()), LENGTH_SHIFT as i64)))))
}

pub fn rack_allocation_layout(count: &Expr) -> Result<(Expr, Expr), String> {
    use crate::kir::{BinOp, ShiftOp};
    use kiln_rt::object::{KIND_RACK, LENGTH_MASK, LENGTH_SHIFT};
    if let Expr::Int(n) = count {
        if *n < 0 || *n as u64 >= LENGTH_MASK { return Err("rack slot count out of range".into()); }
        return Ok((Expr::Int(2 * size_of::<u64>() as i64 + n * size_of::<u64>() as i64),
                   Expr::Int(((((*n as u64) + 1) << LENGTH_SHIFT) | KIND_RACK) as i64)));
    }
    let length = Expr::Bin(BinOp::Add, Box::new(count.clone()), Box::new(Expr::Int(1)));
    Ok((Expr::Bin(BinOp::Add, Box::new(Expr::Int(size_of::<u64>() as i64)),
                  Box::new(Expr::Shift(ShiftOp::Shl, Box::new(length.clone()), 3))),
        Expr::Bin(BinOp::Or, Box::new(Expr::Shift(ShiftOp::Shl, Box::new(length), LENGTH_SHIFT as i64)),
                  Box::new(Expr::Int(KIND_RACK as i64)))))
}

pub fn initialize_structure(result: String, address: String, layout: Expr) -> Vec<Stmt> {
    vec![
        Stmt::Store(Expr::Var(address.clone()), size_of::<u64>() as i32, layout),
        Stmt::Set(result, Expr::Bin(crate::kir::BinOp::Add, Box::new(Expr::Var(address)), Box::new(Expr::Int(TAG_GENERAL as i64)))),
    ]
}

pub fn structure_slot(object: Expr, index: Expr) -> Expr {
    Expr::Load(Box::new(indexed_object_address(object, index)), (2 * size_of::<u64>()) as i32 - TAG_GENERAL as i32)
}

pub fn set_structure_slot(object: Expr, index: Expr, value: Expr) -> Stmt {
    Stmt::Store(indexed_object_address(object, index), (2 * size_of::<u64>()) as i32 - TAG_GENERAL as i32, value)
}

pub fn funcallable_function(object: Expr) -> Expr {
    Expr::Load(Box::new(object), (3 * size_of::<u64>()) as i32 - TAG_GENERAL as i32)
}

pub fn set_funcallable_function(object: Expr, value: Expr) -> Stmt {
    Stmt::Store(object, (3 * size_of::<u64>()) as i32 - TAG_GENERAL as i32, value)
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

pub fn closure_layout(count: i64) -> Result<(i64, i64), String> {
    use kiln_rt::object::{KIND_FUNCTION, LENGTH_MASK, LENGTH_SHIFT};
    if count < 0 || count as u64 > LENGTH_MASK {
        return Err("closure environment length out of range".into());
    }
    let size = (count as u64).checked_mul(size_of::<u64>() as u64)
        .and_then(|n| n.checked_add(size_of::<FunctionObj>() as u64))
        .and_then(|n| i64::try_from(n).ok())
        .ok_or("closure allocation size out of range")?;
    Ok((size, ((count as u64) << LENGTH_SHIFT | KIND_FUNCTION) as i64))
}

pub fn initialize_closure(result: String, address: String, entry: String) -> Vec<Stmt> {
    use crate::kir::BinOp;
    vec![
        Stmt::Store(Expr::Var(address.clone()), core::mem::offset_of!(FunctionObj, entry) as i32, Expr::Addr(entry, 0)),
        Stmt::Set(result, Expr::Bin(BinOp::Add, Box::new(Expr::Var(address)), Box::new(Expr::Int(TAG_GENERAL as i64)))),
    ]
}

pub fn initialize_symbol(result: String, address: String, name: Expr, nil: Expr) -> Vec<Stmt> {
    use crate::kir::BinOp;
    use kiln_rt::object::{SymbolObj, UNBOUND};
    let store = |offset: usize, value| Stmt::Store(Expr::Var(address.clone()), offset as i32, value);
    vec![
        store(core::mem::offset_of!(SymbolObj, name), name),
        store(core::mem::offset_of!(SymbolObj, package), nil.clone()),
        store(core::mem::offset_of!(SymbolObj, function), nil.clone()),
        store(core::mem::offset_of!(SymbolObj, value), Expr::Int(UNBOUND as i64)),
        store(core::mem::offset_of!(SymbolObj, plist), nil.clone()),
        store(core::mem::offset_of!(SymbolObj, setf_function), nil),
        Stmt::Set(result, Expr::Bin(BinOp::Add, Box::new(Expr::Var(address)), Box::new(Expr::Int(TAG_GENERAL as i64)))),
    ]
}

pub fn initialize_stack_closure(result: String, slot: String, entry: String) -> Vec<Stmt> {
    use crate::kir::BinOp;
    vec![
        Stmt::Store(Expr::Slot(slot.clone()), core::mem::offset_of!(FunctionObj, entry) as i32, Expr::Addr(entry, 0)),
        Stmt::Set(result, Expr::Bin(BinOp::Add, Box::new(Expr::Slot(slot)), Box::new(Expr::Int(TAG_GENERAL as i64)))),
    ]
}

pub fn initialize_stack_cons(result: String, address: Expr, car: Expr, cdr: Expr) -> Vec<Stmt> {
    use crate::kir::BinOp;
    vec![
        Stmt::Store(address.clone(), size_of::<u64>() as i32, car),
        Stmt::Store(address.clone(), (2 * size_of::<u64>()) as i32, cdr),
        Stmt::Set(result, Expr::Bin(BinOp::Add, Box::new(address), Box::new(Expr::Int(TAG_CONS as i64)))),
    ]
}

pub fn stack_object_layout(class: u32, count: i64) -> Result<(u32, i64, i32), String> {
    match class {
        CLASS_CONS if count == 2 => Ok((kiln_rt::object::CONS_BYTES as u32, kiln_rt::object::KIND_CONS as i64, size_of::<u64>() as i32)),
        CLASS_FUNCTION => {
            if count > (MAX_EXPANDED_BYTES / EXPANSION_RECORD_BYTES) as i64 {
                return Err("stack closure initialization exceeds expansion budget".into());
            }
            let (size, header) = closure_layout(count)?;
            if size > i32::MAX as i64 { return Err("stack closure too large".into()); }
            Ok((size as u32, header, size_of::<FunctionObj>() as i32))
        }
        _ => Err("invalid stack object class or reference count".into()),
    }
}

pub fn initialize_stack_object(slot: String, class: u32, count: i64) -> Result<Vec<Stmt>, String> {
    let (size, header, _) = stack_object_layout(class, count)?;
    let mut statements = Vec::with_capacity((size / 8) as usize);
    statements.push(Stmt::Store(Expr::Slot(slot.clone()), 0, Expr::Int(header)));
    for offset in (8..size).step_by(8) {
        statements.push(Stmt::Store(Expr::Slot(slot.clone()), offset as i32, Expr::Int(0)));
    }
    Ok(statements)
}

pub fn stack_reference_base(slot: String, class: u32, count: i64) -> Result<Expr, String> {
    let (_, _, offset) = stack_object_layout(class, count)?;
    Ok(Expr::Bin(crate::kir::BinOp::Add, Box::new(Expr::Slot(slot)), Box::new(Expr::Int(offset as i64))))
}

pub fn enter_stack_roots(entry: String, object: String, class: u32, count: i64) -> Result<Vec<Stmt>, String> {
    use kiln_rt::context::{Context, DynEntry, DYN_STACK_ROOTS};
    let field = |offset: usize, value| Stmt::Store(Expr::Slot(entry.clone()), offset as i32, value);
    let context = || Expr::Var("ctx".into());
    let dynenv = core::mem::offset_of!(Context, dynenv) as i32;
    Ok(vec![
        field(core::mem::offset_of!(DynEntry, kind), Expr::Int(DYN_STACK_ROOTS as i64)),
        field(core::mem::offset_of!(DynEntry, prev), Expr::Load(Box::new(context()), dynenv)),
        field(core::mem::offset_of!(DynEntry, fp), Expr::Fp),
        field(core::mem::offset_of!(DynEntry, tag), Expr::Int(0)),
        field(core::mem::offset_of!(DynEntry, pend_target), stack_reference_base(object, class, count)?),
        field(core::mem::offset_of!(DynEntry, pend_value), Expr::Int(count)),
        Stmt::Store(context(), dynenv, Expr::Slot(entry)),
    ])
}

pub fn dynamic_entry_kind(kind: &str) -> Result<i64, String> {
    use kiln_rt::context::*;
    Ok(match kind {
        "catch" => DYN_CATCH,
        "unwind-protect" => DYN_UNWIND_PROTECT,
        "exit-point" => DYN_EXIT_POINT,
        "bind" => DYN_BIND,
        "progv" => DYN_PROGV,
        _ => return Err(format!("unknown dynamic entry kind {kind}")),
    } as i64)
}

pub fn enter_dynamic_entry(entry: String, kind: &str, tag: Expr) -> Result<Vec<Stmt>, String> {
    use kiln_rt::context::{Context, DynEntry};
    let field = |offset: usize, value| Stmt::Store(Expr::Slot(entry.clone()), offset as i32, value);
    let context = || Expr::Var("ctx".into());
    let dynenv = core::mem::offset_of!(Context, dynenv) as i32;
    Ok(vec![
        field(core::mem::offset_of!(DynEntry, kind), Expr::Int(dynamic_entry_kind(kind)?)),
        field(core::mem::offset_of!(DynEntry, prev), Expr::Load(Box::new(context()), dynenv)),
        field(core::mem::offset_of!(DynEntry, fp), Expr::Fp),
        field(core::mem::offset_of!(DynEntry, tag), tag),
        field(core::mem::offset_of!(DynEntry, pend_target), Expr::Int(0)),
        field(core::mem::offset_of!(DynEntry, pend_value), Expr::Int(0)),
        Stmt::Store(context(), dynenv, Expr::Slot(entry)),
    ])
}

pub fn leave_dynamic_entry(entry: String) -> Stmt {
    use kiln_rt::context::{Context, DynEntry};
    Stmt::Store(Expr::Var("ctx".into()), core::mem::offset_of!(Context, dynenv) as i32,
        Expr::Load(Box::new(Expr::Slot(entry)), core::mem::offset_of!(DynEntry, prev) as i32))
}

pub fn bind_special(entry: String, index: Expr, address: Expr, value: Expr) -> Vec<Stmt> {
    use kiln_rt::context::DynEntry;
    vec![
        Stmt::Store(Expr::Slot(entry.clone()), core::mem::offset_of!(DynEntry, pend_target) as i32, index),
        Stmt::Store(Expr::Slot(entry), core::mem::offset_of!(DynEntry, pend_value) as i32,
                    Expr::Load(Box::new(address.clone()), 0)),
        Stmt::Store(address, 0, value),
    ]
}

pub fn bind_special_index(entry: String, temporary: String, index: Expr, value: Expr) -> Vec<Stmt> {
    let mut statements = vec![Stmt::Set(temporary.clone(), tls_address(index.clone()))];
    statements.extend(bind_special(entry, index, Expr::Var(temporary), value));
    statements
}

pub fn unbind_special(entry: String) -> Stmt {
    use kiln_rt::context::DynEntry;
    let field = |offset: usize| Expr::Load(Box::new(Expr::Slot(entry.clone())), offset as i32);
    let index = field(core::mem::offset_of!(DynEntry, pend_target));
    Stmt::Store(tls_address(index), 0, field(core::mem::offset_of!(DynEntry, pend_value)))
}

pub fn progv_bindings(result: String, entry: String) -> Stmt {
    Stmt::Set(result, Expr::Load(Box::new(Expr::Slot(entry)), core::mem::offset_of!(kiln_rt::context::DynEntry, tag) as i32))
}

pub fn relink_dynamic_entry(entry: String) -> Stmt {
    Stmt::Store(Expr::Var("ctx".into()), core::mem::offset_of!(kiln_rt::context::Context, dynenv) as i32, Expr::Slot(entry))
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

fn transfer_address(index: Expr) -> Expr {
    Expr::Bin(
        crate::kir::BinOp::Add,
        Box::new(Expr::Var("ctx".into())),
        Box::new(Expr::Shift(crate::kir::ShiftOp::Shl, Box::new(index), 3)),
    )
}

pub fn transfer_ref_dynamic(index: Expr) -> Expr {
    Expr::Load(Box::new(transfer_address(index)), core::mem::offset_of!(kiln_rt::context::Context, values) as i32)
}

pub fn transfer_set_dynamic(index: Expr, value: Expr) -> Stmt {
    Stmt::Store(transfer_address(index), core::mem::offset_of!(kiln_rt::context::Context, values) as i32, value)
}

pub fn transfer_roots(count: Expr) -> Stmt {
    Stmt::Store(
        Expr::Var("ctx".into()),
        core::mem::offset_of!(kiln_rt::context::Context, values_live) as i32,
        count,
    )
}

pub fn fixed_layout(class: u32) -> Result<(i64, i64, i64, usize), String> {
    use kiln_rt::object::*;
    match class {
        CLASS_CONS => Ok((CONS_BYTES as i64, KIND_CONS as i64, TAG_CONS as i64, 2)),
        CLASS_COMPLEX => Ok((3 * size_of::<u64>() as i64, KIND_COMPLEX as i64, TAG_GENERAL as i64, 2)),
        CLASS_DOUBLE => Ok((2 * size_of::<u64>() as i64, KIND_DOUBLE as i64, TAG_GENERAL as i64, 1)),
        CLASS_INSTANCE => Ok((2 * size_of::<u64>() as i64, KIND_INSTANCE as i64, TAG_GENERAL as i64, 1)),
        CLASS_FUNCALLABLE_INSTANCE => Ok((4 * size_of::<u64>() as i64, (KIND_FUNCALLABLE_INSTANCE | (2 << LENGTH_SHIFT)) as i64, TAG_GENERAL as i64, 3)),
        _ => Err(format!("unsupported fixed allocation class {class}")),
    }
}

pub fn initialize_fixed(result: String, address: String, class: u32, fields: Vec<Expr>) -> Result<Vec<Stmt>, String> {
    use crate::kir::BinOp;
    let (_, _, tag, count) = fixed_layout(class)?;
    if fields.len() != count { return Err("fixed allocation: wrong field count".into()); }
    let mut stmts = vec![Stmt::Set(result.clone(), Expr::Bin(BinOp::Add, Box::new(Expr::Var(address)), Box::new(Expr::Int(tag))))];
    for (index, value) in fields.into_iter().enumerate() {
        let offset = ((index + 1) * size_of::<u64>()) as i32 - tag as i32;
        stmts.push(Stmt::Store(Expr::Var(result.clone()), offset, value));
    }
    Ok(stmts)
}

pub fn vector_layout(class: u32, length: &Expr) -> Result<(Expr, Expr, u32), String> {
    use crate::kir::{BinOp, ShiftOp};
    use kiln_rt::object::{KIND_SIMPLE_VECTOR, KIND_STRING, LENGTH_SHIFT};
    let (kind, shift) = match class {
        CLASS_SIMPLE_VECTOR => (KIND_SIMPLE_VECTOR, 3),
        CLASS_STRING => (KIND_STRING, 2),
        _ => return Err("unsupported vector allocation class".into()),
    };
    if let Expr::Int(n) = length {
        if !(0..=u32::MAX as i64).contains(n) { return Err("vector length out of range".into()); }
        let bytes = 8 + (((n << shift) + 7) & !7);
        return Ok((Expr::Int(bytes), Expr::Int((n << LENGTH_SHIFT) | kind as i64), shift));
    }
    let payload = Expr::Shift(ShiftOp::Shl, Box::new(length.clone()), shift as i64);
    let aligned = if shift == 2 {
        Expr::Bin(BinOp::And, Box::new(Expr::Bin(BinOp::Add, Box::new(payload), Box::new(Expr::Int(7)))), Box::new(Expr::Int(-8)))
    } else { payload };
    Ok((Expr::Bin(BinOp::Add, Box::new(Expr::Int(8)), Box::new(aligned)),
        Expr::Bin(BinOp::Or, Box::new(Expr::Shift(ShiftOp::Shl, Box::new(length.clone()), LENGTH_SHIFT as i64)), Box::new(Expr::Int(kind as i64))), shift))
}

pub fn initialize_vector_elements(result: String, address: String, values: Vec<Expr>) -> Vec<Stmt> {
    use crate::kir::BinOp;
    let mut stmts = Vec::with_capacity(values.len() + 1);
    stmts.push(Stmt::Set(result.clone(), Expr::Bin(BinOp::Add, Box::new(Expr::Var(address)), Box::new(Expr::Int(TAG_GENERAL as i64)))));
    for (index, value) in values.into_iter().enumerate() {
        let offset = ((index + 1) * size_of::<u64>()) as i32 - TAG_GENERAL as i32;
        stmts.push(Stmt::Store(Expr::Var(result.clone()), offset, value));
    }
    stmts
}

#[allow(clippy::too_many_arguments, clippy::type_complexity)]
pub fn initialize_vector(name: &str, block: String, mut preceding: Vec<Stmt>, result: String,
                         address: String, length: Expr, value: Expr, shift: u32)
    -> (Vec<(String, crate::kir::VarKind)>, Vec<crate::kir::Block>, String, Vec<Stmt>) {
    use crate::kir::{BinOp, Block, CmpOp, ShiftOp, VarKind};
    let var = |s: &str| Expr::Var(s.to_string());
    preceding.push(Stmt::Set(result, Expr::Bin(BinOp::Add, Box::new(var(&address)), Box::new(Expr::Int(TAG_GENERAL as i64)))));
    if matches!(value, Expr::Int(0)) { return (vec![], vec![], block, preceding); }
    let store = |index: Expr| {
        let base = Expr::Bin(BinOp::Add, Box::new(var(&address)), Box::new(Expr::Shift(ShiftOp::Shl, Box::new(index), shift as i64)));
        if shift == 2 { Stmt::Store32(base, 8, value.clone()) } else { Stmt::Store(base, 8, value.clone()) }
    };
    if let Expr::Int(n @ 0..=15) = length {
        for i in 0..n { preceding.push(store(Expr::Int(i))); }
        return (vec![], vec![], block, preceding);
    }
    let index = format!("{name}_index");
    let head = format!("{name}_fill_head");
    let body = format!("{name}_fill_body");
    let done = format!("{name}_fill_done");
    preceding.push(Stmt::Set(index.clone(), Expr::Int(0)));
    preceding.push(Stmt::Jump(head.clone()));
    let blocks = vec![
        Block { name: block, stmts: preceding },
        Block { name: head, stmts: vec![Stmt::Br(Expr::Cmp(CmpOp::Lt, Box::new(var(&index)), Box::new(length)), body.clone(), done.clone())] },
        Block { name: body, stmts: vec![store(var(&index)), Stmt::Set(index.clone(), Expr::Bin(BinOp::Add, Box::new(var(&index)), Box::new(Expr::Int(1)))), Stmt::Jump(format!("{name}_fill_head"))] },
    ];
    (vec![(index, VarKind::Raw)], blocks, done, vec![])
}

/// Expand allocation after operand evaluation; only the slow path can safepoint.
#[allow(clippy::too_many_arguments, clippy::type_complexity)]
pub fn allocate_raw(
    name: &str, block: String, mut preceding: Vec<Stmt>, result: String,
    bytes: Expr, header: Expr, zero: bool, runtime: String, handler: Option<String>,
) -> Result<(Vec<(String, crate::kir::VarKind)>, Vec<crate::kir::Block>, String, Vec<Stmt>), String> {
    use crate::kir::{BinOp, Block, CmpOp, VarKind};
    use kiln_rt::context::Context;
    let slow_call = || Stmt::CallRt {
        name: runtime.clone(), results: vec![result.clone()],
        args: vec![Expr::Var("ctx".into()), bytes.clone(), header.clone()],
        handler: handler.clone(), loc: None,
    };
    let size = match bytes {
        Expr::Int(n) if (8..=128).contains(&n) && n % 8 == 0 => n,
        _ => {
            preceding.push(slow_call());
            return Ok((vec![], vec![], block, preceding));
        }
    };
    let cursor = format!("{name}_cursor");
    let end = format!("{name}_end");
    let fast = format!("{name}_fast");
    let slow = format!("{name}_slow");
    let done = format!("{name}_done");
    let var = |s: &str| Expr::Var(s.to_string());
    preceding.push(Stmt::Set(cursor.clone(), Expr::Load(Box::new(var("ctx")), core::mem::offset_of!(Context, alloc_cursor) as i32)));
    preceding.push(Stmt::Set(result.clone(), Expr::Load(Box::new(var(&cursor)), 0)));
    preceding.push(Stmt::Set(end.clone(), Expr::Bin(BinOp::Add, Box::new(var(&result)), Box::new(Expr::Int(size)))));
    let limit = Expr::Load(Box::new(Expr::Load(Box::new(var("ctx")), core::mem::offset_of!(Context, alloc_limit) as i32)), 0);
    preceding.push(Stmt::Br(Expr::Cmp(CmpOp::Le, Box::new(var(&end)), Box::new(limit)), fast.clone(), slow.clone()));
    let mut fast_stmts = vec![Stmt::Store(var(&cursor), 0, var(&end)), Stmt::Store(var(&result), 0, header.clone())];
    if zero {
        for offset in (8..size).step_by(8) {
            fast_stmts.push(Stmt::Store(var(&result), offset as i32, Expr::Int(0)));
        }
    }
    fast_stmts.push(Stmt::Jump(done.clone()));
    let blocks = vec![
        Block { name: block, stmts: preceding },
        Block { name: fast, stmts: fast_stmts },
        Block { name: slow, stmts: vec![slow_call(), Stmt::Jump(done.clone())] },
    ];
    Ok((vec![(cursor, VarKind::Raw), (end, VarKind::Raw)], blocks, done, vec![]))
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
        assert!(field_store(FIELD_DOUBLE_BITS, Expr::Int(0), Expr::Int(0)).is_err());
    }
}
