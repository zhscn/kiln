//! Backend-owned Lisp entries with fixed runtime roles.
use super::*;
use crate::kir::{Block, CmpOp, Data, DataContents, Func, ImportFunc, Module, VarKind, Word};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    UndefinedFunction,
    UndefinedSetfFunction,
    FuncallableTrampoline,
    FuncallableUnset,
}
impl Kind {
    pub fn parse(name: &str) -> Result<Self, String> {
        Ok(match name {
            "undefined-function" => Self::UndefinedFunction,
            "undefined-setf-function" => Self::UndefinedSetfFunction,
            "funcallable-trampoline" => Self::FuncallableTrampoline,
            "funcallable-unset" => Self::FuncallableUnset,
            _ => return Err("unknown backend builtin".into()),
        })
    }
    pub fn entry(self) -> &'static str {
        match self {
            Self::UndefinedFunction => "kiln_undefined_function",
            Self::UndefinedSetfFunction => "kiln_undefined_setf_function",
            Self::FuncallableTrampoline => "kiln_funcallable_trampoline",
            Self::FuncallableUnset => "kiln_funcallable_unset",
        }
    }
    pub fn object(self) -> Result<&'static str, String> {
        if self == Self::FuncallableUnset {
            Ok("kiln_funcallable_unset_fobj")
        } else {
            Err("builtin has no zero-capture object".into())
        }
    }
}
fn import_data(module: &mut Module, name: &str) {
    if !module.data.iter().any(|d| d.name == name)
        && !module.funcs.iter().any(|f| f.name == name)
        && !module.import_data.iter().any(|n| n == name)
    {
        module.import_data.push(name.into());
    }
}
pub fn install(module: &mut Module, kind: Kind, image: bool) -> Result<(), String> {
    if image {
        import_data(module, kind.entry());
        if kind == Kind::FuncallableUnset {
            import_data(module, kind.object()?);
        }
        return Ok(());
    }
    if module.funcs.iter().any(|f| f.name == kind.entry()) {
        return Ok(());
    }
    let mut vars = vec![];
    let blocks = if kind == Kind::FuncallableTrampoline {
        vars.push(("function".into(), VarKind::Obj));
        vec![Block {
            name: "entry".into(),
            stmts: vec![
                Stmt::Set(
                    "function".into(),
                    funcallable_function(Expr::Var("self".into())),
                ),
                arguments::forward_incoming(Expr::Var("function".into()))?,
            ],
        }]
    } else {
        let (code, value) = match kind {
            Kind::UndefinedFunction => (
                kiln_rt::rtfun::ERR_UNDEFINED_FUNCTION,
                closure_ref(Expr::Var("self".into()), 0)?,
            ),
            Kind::UndefinedSetfFunction => (
                kiln_rt::rtfun::ERR_UNDEFINED_SETF_FUNCTION,
                closure_ref(Expr::Var("self".into()), 0)?,
            ),
            Kind::FuncallableUnset => (kiln_rt::rtfun::ERR_NOT_FUNCTION, Expr::Var("self".into())),
            _ => unreachable!(),
        };
        let (extra, mut blocks, last, stmts) = runtime_error(
            "failure",
            "entry".into(),
            vec![],
            code as i64,
            value,
            None,
            None,
        )?;
        vars.extend(extra);
        blocks.push(Block { name: last, stmts });
        blocks
    };
    module.import_data.retain(|n| n != kind.entry());
    module.shared.insert(kind.entry().into());
    module.funcs.push(Func {
        name: kind.entry().into(),
        vars,
        labels: vec![],
        slots: vec![],
        blocks,
        debug: None,
    });
    if kind == Kind::FuncallableUnset {
        let name = kind.object()?;
        module.import_data.retain(|n| n != name);
        module.shared.insert(name.into());
        module.data.push(Data {
            name: name.into(),
            contents: DataContents::Words(vec![
                Word::Int(kiln_rt::object::KIND_FUNCTION as i64),
                Word::FuncAddr(kind.entry().into()),
            ]),
        });
    }
    Ok(())
}
pub fn register_error_imports(module: &mut Module) -> Result<(), String> {
    let used = module
        .funcs
        .iter()
        .flat_map(|f| &f.blocks)
        .flat_map(|b| &b.stmts)
        .any(|s| matches!(s,Stmt::CallRt {name,..} if name=="kiln_rt_error"));
    if !used {
        return Ok(());
    }
    if let Some(f) = module
        .import_funcs
        .iter()
        .find(|f| f.name == "kiln_rt_error")
    {
        if f.params != 3 || f.returns != 0 || !f.unwinds || !f.noreturn {
            return Err("error signaling requires the runtime error signature".into());
        }
    } else {
        module.import_funcs.push(ImportFunc {
            name: "kiln_rt_error".into(),
            params: 3,
            returns: 0,
            unwinds: true,
            noreturn: true,
        });
    }
    for name in [
        "kiln_nil",
        kiln_rt::RUNTIME_ERROR_SYMBOL,
        Kind::UndefinedFunction.entry(),
    ] {
        import_data(module, name);
    }
    Ok(())
}
pub fn undefined_function(function: Expr) -> Result<Expr, String> {
    let entry = field_load(FIELD_FUNCTION_ENTRY, function)?;
    Ok(Expr::Bin(
        crate::kir::BinOp::Or,
        Box::new(Expr::Cmp(
            CmpOp::Eq,
            Box::new(entry.clone()),
            Box::new(Expr::Addr(Kind::UndefinedFunction.entry().into(), 0)),
        )),
        Box::new(Expr::Cmp(
            CmpOp::Eq,
            Box::new(entry),
            Box::new(Expr::Addr(Kind::UndefinedSetfFunction.entry().into(), 0)),
        )),
    ))
}

pub fn allocate_undefined(
    prefix: &str,
    start: String,
    mut before: Vec<Stmt>,
    result: String,
    symbol: Expr,
    setf: bool,
    handler: Option<String>,
) -> Result<values::Expansion, String> {
    let saved = format!("{prefix}_symbol");
    let raw = format!("{prefix}_object");
    before.push(Stmt::Set(saved.clone(), symbol));
    let (bytes, header) = closure_layout(1)?;
    let (mut vars, blocks, next, mut stmts) = allocate_raw(
        prefix,
        start,
        before,
        raw.clone(),
        Expr::Int(bytes),
        Expr::Int(header),
        true,
        "kiln_rt_alloc".into(),
        handler,
    )?;
    vars.extend([(saved.clone(), VarKind::Obj), (raw.clone(), VarKind::Raw)]);
    stmts.extend(initialize_closure(
        result.clone(),
        raw,
        if setf {
            Kind::UndefinedSetfFunction
        } else {
            Kind::UndefinedFunction
        }
        .entry()
        .into(),
    ));
    stmts.push(closure_set(Expr::Var(result), 0, Expr::Var(saved))?);
    Ok((vars, blocks, next, stmts))
}
pub fn allocate_funcallable(
    prefix: &str,
    start: String,
    mut before: Vec<Stmt>,
    result: String,
    rack: Expr,
    handler: Option<String>,
) -> Result<values::Expansion, String> {
    let saved = format!("{prefix}_rack");
    let raw = format!("{prefix}_object");
    before.push(Stmt::Set(saved.clone(), rack));
    let (bytes, header, _, _) = fixed_layout(CLASS_FUNCALLABLE_INSTANCE)?;
    let (mut vars, blocks, next, mut stmts) = allocate_raw(
        prefix,
        start,
        before,
        raw.clone(),
        Expr::Int(bytes),
        Expr::Int(header),
        true,
        "kiln_rt_alloc".into(),
        handler,
    )?;
    vars.extend([(saved.clone(), VarKind::Obj), (raw.clone(), VarKind::Raw)]);
    stmts.extend(initialize_fixed(
        result,
        raw,
        CLASS_FUNCALLABLE_INSTANCE,
        vec![
            Expr::Addr(Kind::FuncallableTrampoline.entry().into(), 0),
            Expr::Var(saved),
            Expr::Addr(Kind::FuncallableUnset.object()?.into(), TAG_GENERAL as i64),
        ],
    )?);
    Ok((vars, blocks, next, stmts))
}
