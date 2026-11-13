//! Poll checks, slow paths, and entry argument preservation.
use super::values::Expansion;
use super::*;
use crate::kir::{Block, CmpOp, Func, ImportFunc, Module, VarKind};

pub const RETRY: &str = "kiln_poll_retry";
fn var(name: impl Into<String>) -> Expr {
    Expr::Var(name.into())
}
fn object(name: &str) -> Expr {
    Expr::Addr(name.into(), TAG_GENERAL as i64)
}
type Statements = (Vec<(String, VarKind)>, Vec<Stmt>);

fn overflow(prefix: &str, handler: Option<String>) -> Result<Statements, String> {
    let f = format!("{prefix}_function");
    let v = format!("{prefix}_primary");
    let n = format!("{prefix}_count");
    let mut stmts = vec![Stmt::Set(
        f.clone(),
        field_load(
            FIELD_SYMBOL_FUNCTION,
            object(kiln_rt::STACK_EXHAUSTED_SYMBOL),
        )?,
    )];
    stmts.extend(invoke(
        v.clone(),
        n.clone(),
        f.clone(),
        vec![],
        handler,
        None,
    )?);
    Ok((
        vec![(f, VarKind::Obj), (v, VarKind::Obj), (n, VarKind::Raw)],
        stmts,
    ))
}

pub fn expand(
    prefix: &str,
    start: String,
    mut before: Vec<Stmt>,
    entry: bool,
    retry: bool,
    handler: Option<String>,
) -> Result<Expansion, String> {
    if retry && (!entry || handler.is_some()) {
        return Err("entry retry poll requires an unprotected entry".into());
    }
    let slow = format!("{prefix}_slow");
    let full = format!("{prefix}_overflow");
    let done = format!("{prefix}_done");
    let exhausted = format!("{prefix}_exhausted");
    before.push(Stmt::Br(
        poll_test(if entry { "entry" } else { "loop" })?,
        slow.clone(),
        done.clone(),
    ));
    let mut blocks = vec![Block {
        name: start,
        stmts: before,
    }];
    if retry {
        blocks.push(Block {
            name: slow,
            stmts: vec![Stmt::TailCallLisp {
                entry: Expr::Addr(RETRY.into(), 0),
                args: std::iter::once(var("ctx"))
                    .chain([var("self"), var("nargs")])
                    .chain((0..crate::kir::REG_ARGS).map(|i| var(format!("a{i}"))))
                    .collect(),
            }],
        });
        return Ok((vec![], blocks, done, vec![]));
    }
    blocks.push(Block {
        name: slow,
        stmts: vec![
            Stmt::CallRt {
                name: "kiln_rt_poll".into(),
                results: vec![exhausted.clone()],
                args: vec![var("ctx"), Expr::Int(0)],
                handler: handler.clone(),
                loc: None,
            },
            Stmt::Br(var(&exhausted), full.clone(), done.clone()),
        ],
    });
    let (mut vars, mut stmts) = overflow(prefix, handler)?;
    vars.push((exhausted, VarKind::Raw));
    stmts.push(Stmt::Jump(done.clone()));
    blocks.push(Block { name: full, stmts });
    Ok((vars, blocks, done, vec![]))
}

fn retry_function() -> Result<Func, String> {
    let mut vars = vec![
        ("saved_self".into(), VarKind::Obj),
        ("entry".into(), VarKind::Raw),
        ("exhausted".into(), VarKind::Raw),
    ];
    let mut stmts = vec![
        Stmt::Set("saved_self".into(), var("self")),
        Stmt::Set(
            "entry".into(),
            field_load(FIELD_FUNCTION_ENTRY, var("self"))?,
        ),
    ];
    let mut args = vec![var("ctx"), var("saved_self"), var("nargs")];
    for i in 0..crate::kir::REG_ARGS {
        let name = format!("saved_arg{i}");
        vars.push((name.clone(), VarKind::Obj));
        stmts.push(Stmt::Set(
            name.clone(),
            Expr::Select(
                Box::new(Expr::Cmp(
                    CmpOp::Gt,
                    Box::new(var("nargs")),
                    Box::new(Expr::Int(i as i64)),
                )),
                Box::new(var(format!("a{i}"))),
                Box::new(Expr::Int(0)),
            ),
        ));
        args.push(var(name));
    }
    stmts.push(Stmt::CallRt {
        name: "kiln_rt_poll".into(),
        results: vec!["exhausted".into()],
        args: vec![var("ctx"), var("entry")],
        handler: None,
        loc: None,
    });
    stmts.push(Stmt::Br(
        var("exhausted"),
        "overflow".into(),
        "again".into(),
    ));
    let (extra, mut full) = overflow("failure", None)?;
    vars.extend(extra);
    full.push(Stmt::Jump("again".into()));
    Ok(Func {
        name: RETRY.into(),
        vars,
        labels: vec![],
        slots: vec![],
        debug: None,
        blocks: vec![
            Block {
                name: "entry".into(),
                stmts,
            },
            Block {
                name: "overflow".into(),
                stmts: full,
            },
            Block {
                name: "again".into(),
                stmts: vec![Stmt::TailCallLisp {
                    entry: var("entry"),
                    args,
                }],
            },
        ],
    })
}

pub fn register(module: &mut Module) -> Result<(), String> {
    let retry = module
        .funcs
        .iter()
        .flat_map(|f| &f.blocks)
        .flat_map(|b| &b.stmts)
        .any(|s| matches!(s,Stmt::TailCallLisp {entry:Expr::Addr(n,0),..} if n==RETRY));
    if retry
        && !module.funcs.iter().any(|f| f.name == RETRY)
        && !module.import_data.iter().any(|n| n == RETRY)
    {
        module.shared.insert(RETRY.into());
        module.funcs.push(retry_function()?);
    }

    let used = module
        .funcs
        .iter()
        .flat_map(|f| &f.blocks)
        .flat_map(|b| &b.stmts)
        .any(|s| matches!(s,Stmt::CallRt {name,..} if name=="kiln_rt_poll"));
    if !used {
        return Ok(());
    }
    if let Some(f) = module
        .import_funcs
        .iter()
        .find(|f| f.name == "kiln_rt_poll")
    {
        if f.params != 2 || f.returns != 1 || !f.unwinds || f.noreturn {
            return Err("poll requires the runtime poll signature".into());
        }
    } else {
        module.import_funcs.push(ImportFunc {
            name: "kiln_rt_poll".into(),
            params: 2,
            returns: 1,
            unwinds: true,
            noreturn: false,
        });
    }
    let name = kiln_rt::STACK_EXHAUSTED_SYMBOL;
    if !module.data.iter().any(|d| d.name == name) && !module.import_data.iter().any(|n| n == name)
    {
        module.import_data.push(name.into());
    }
    Ok(())
}
