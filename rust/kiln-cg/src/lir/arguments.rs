//! Entry argument materialization before the incoming transfer area is reused.
use super::*;
use crate::kir::{BinOp, Block, CmpOp, VarKind};

type Expansion = (Vec<(String, VarKind)>, Vec<Block>, String, Vec<Stmt>);

/// Forwards an untouched incoming argument sequence without a safepoint.
pub fn forward_incoming(callee: Expr) -> Result<Stmt, String> {
    let mut args = vec![
        Expr::Var("ctx".into()),
        callee.clone(),
        Expr::Var("nargs".into()),
    ];
    args.extend((0..crate::kir::REG_ARGS).map(|i| Expr::Var(format!("a{i}"))));
    Ok(Stmt::TailCallLisp {
        entry: field_load(FIELD_FUNCTION_ENTRY, callee)?,
        args,
    })
}

/// Saves the requested prefix before a safepoint can reuse incoming values.
pub fn receive_prefix(names: &[String], count: Option<String>) -> Result<Vec<Stmt>, String> {
    let limit = crate::kir::REG_ARGS + kiln_rt::context::VALUES_MAX;
    if names.len() > limit
        || names.iter().collect::<std::collections::HashSet<_>>().len() != names.len()
        || count.as_ref().is_some_and(|n| names.contains(n))
    {
        return Err("invalid receive prefix".into());
    }
    let mut stmts = Vec::new();
    if let Some(count) = count {
        stmts.push(Stmt::Set(count, Expr::Var("nargs".into())));
    }
    let registers = (0..crate::kir::REG_ARGS)
        .map(|i| Expr::Var(format!("a{i}")))
        .collect::<Vec<_>>();
    for (i, name) in names.iter().enumerate() {
        stmts.push(Stmt::Set(
            name.clone(),
            Expr::Select(
                Box::new(Expr::Cmp(
                    CmpOp::Gt,
                    Box::new(Expr::Var("nargs".into())),
                    Box::new(Expr::Int(i as i64)),
                )),
                Box::new(argument_ref(i as i64, registers.clone())?),
                Box::new(Expr::Addr("kiln_nil".into(), TAG_GENERAL as i64)),
            ),
        ));
    }
    Ok(stmts)
}

#[allow(clippy::too_many_arguments)]
pub fn rest_list(
    prefix: &str,
    start: String,
    mut before: Vec<Stmt>,
    result: String,
    first: usize,
    registers: Vec<Expr>,
    slots: &[String],
    handler: Option<String>,
) -> Result<Expansion, String> {
    let limit = crate::kir::REG_ARGS + kiln_rt::context::VALUES_MAX;
    if slots.iter().collect::<std::collections::HashSet<_>>().len() != slots.len() {
        return Err("duplicate rest stack slot".into());
    }
    if first > limit || registers.len() != crate::kir::REG_ARGS || slots.len() > limit {
        return Err("invalid rest argument declaration".into());
    }
    let name = |suffix: &str| format!("{prefix}_{suffix}");
    let var = |name: &str| Expr::Var(name.into());
    let mut vars = Vec::new();
    let mut saved = Vec::new();
    for (i, value) in registers.into_iter().enumerate() {
        let r = name(&format!("arg{i}"));
        vars.push((r.clone(), VarKind::Obj));
        before.push(Stmt::Set(
            r.clone(),
            Expr::Select(
                Box::new(Expr::Cmp(
                    CmpOp::Gt,
                    Box::new(var("nargs")),
                    Box::new(Expr::Int(i as i64)),
                )),
                Box::new(value),
                Box::new(Expr::Addr("kiln_nil".into(), TAG_GENERAL as i64)),
            ),
        ));
        saved.push(var(&r));
    }
    let index = name("index");
    let car = name("car");
    let tail = name("tail");
    let raw = name("raw");
    vars.extend([
        (index.clone(), VarKind::Raw),
        (car.clone(), VarKind::Obj),
        (tail.clone(), VarKind::Obj),
        (raw.clone(), VarKind::Raw),
    ]);
    let head = name("head");
    let body = name("body");
    let done = name("done");
    before.push(counted_transfer_roots(var("nargs"), true)?);
    before.push(Stmt::Set(
        result.clone(),
        Expr::Addr("kiln_nil".into(), TAG_GENERAL as i64),
    ));
    before.push(Stmt::Set(index.clone(), var("nargs")));
    before.push(Stmt::Jump(head.clone()));
    let mut blocks = vec![
        Block {
            name: start,
            stmts: before,
        },
        Block {
            name: head.clone(),
            stmts: vec![Stmt::Br(
                Expr::Cmp(
                    CmpOp::Gt,
                    Box::new(var(&index)),
                    Box::new(Expr::Int(first as i64)),
                ),
                body.clone(),
                done.clone(),
            )],
        },
    ];
    let before = vec![
        Stmt::Set(
            index.clone(),
            Expr::Bin(BinOp::Sub, Box::new(var(&index)), Box::new(Expr::Int(1))),
        ),
        Stmt::Set(tail.clone(), var(&result)),
    ];
    let (read, current) = argument_read(
        &name("read"),
        body,
        before,
        car.clone(),
        index.clone(),
        saved,
    )?;
    blocks.extend(read);
    let heap = name("heap");
    if !slots.is_empty() {
        let stack = name("stack");
        blocks.push(Block {
            name: current,
            stmts: vec![Stmt::Br(
                Expr::Cmp(
                    CmpOp::Le,
                    Box::new(var("nargs")),
                    Box::new(Expr::Int((first + slots.len()) as i64)),
                ),
                stack.clone(),
                heap.clone(),
            )],
        });
        let mut address = Expr::Slot(slots[0].clone());
        for (i, slot) in slots.iter().enumerate().skip(1) {
            address = Expr::Select(
                Box::new(Expr::Cmp(
                    CmpOp::Eq,
                    Box::new(var(&index)),
                    Box::new(Expr::Int((first + i) as i64)),
                )),
                Box::new(Expr::Slot(slot.clone())),
                Box::new(address),
            );
        }
        let mut statements = initialize_stack_cons(result.clone(), address, var(&car), var(&tail));
        statements.push(Stmt::Jump(head.clone()));
        blocks.push(Block {
            name: stack,
            stmts: statements,
        });
    } else {
        blocks.push(Block {
            name: current,
            stmts: vec![Stmt::Jump(heap.clone())],
        });
    }
    let (bytes, header, _, _) = fixed_layout(CLASS_CONS)?;
    let (temps, allocation, next, mut statements) = allocate_raw(
        &name("alloc"),
        heap,
        vec![],
        raw.clone(),
        Expr::Int(bytes),
        Expr::Int(header),
        true,
        "kiln_rt_alloc".into(),
        handler,
    )?;
    vars.extend(temps);
    blocks.extend(allocation);
    statements.extend(initialize_fixed(
        result,
        raw,
        CLASS_CONS,
        vec![var(&car), var(&tail)],
    )?);
    statements.push(Stmt::Jump(head));
    blocks.push(Block {
        name: next,
        stmts: statements,
    });
    Ok((vars, blocks, done, vec![transfer_roots(Expr::Int(0))]))
}
