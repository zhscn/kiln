//! KIR: kiln's low-level IR, the interchange format between the Lisp
//! compiler and this code generator. Grammar: docs/06-m0-abi.md.
//!
//! KIR is close to Cranelift IR but uses mutable variables instead of SSA
//! values and block parameters; cranelift-frontend builds the SSA form.

use crate::sexp::Sexp;

#[derive(Debug)]
pub struct Module {
    pub name: String,
    pub init: String,
    pub import_funcs: Vec<ImportFunc>,
    pub import_data: Vec<String>,
    pub data: Vec<Data>,
    pub funcs: Vec<Func>,
}

#[derive(Debug, Clone)]
pub struct ImportFunc {
    pub name: String,
    pub params: usize,
    pub returns: usize,
    /// Called through a `tail` trampoline that passes its frame pointer.
    pub unwinds: bool,
    pub noreturn: bool,
}

#[derive(Debug)]
pub struct Data {
    pub name: String,
    pub contents: DataContents,
}

#[derive(Debug)]
pub enum DataContents {
    Words(Vec<Word>),
    Bytes(Vec<u8>),
}

#[derive(Debug)]
pub enum Word {
    Int(i64),
    DataAddr(String, i64),
    FuncAddr(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VarKind {
    /// Holds a Lisp object; tracked in stack maps.
    Obj,
    /// Holds a raw machine word.
    Raw,
}

#[derive(Debug)]
pub struct Func {
    pub name: String,
    pub vars: Vec<(String, VarKind)>,
    pub slots: Vec<(String, u32)>,
    pub blocks: Vec<Block>,
}

#[derive(Debug)]
pub struct Block {
    pub name: String,
    pub stmts: Vec<Stmt>,
}

#[derive(Debug, Clone, Copy)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    And,
    Or,
    Xor,
}

#[derive(Debug, Clone, Copy)]
pub enum ShiftOp {
    Shl,
    Sar,
    Shr,
}

#[derive(Debug, Clone, Copy)]
pub enum CmpOp {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}

#[derive(Debug, Clone, Copy)]
pub enum OvfOp {
    Add,
    Sub,
    Mul,
}

#[derive(Debug)]
pub enum Expr {
    Int(i64),
    Var(String),
    Bin(BinOp, Box<Expr>, Box<Expr>),
    Shift(ShiftOp, Box<Expr>, i64),
    Cmp(CmpOp, Box<Expr>, Box<Expr>),
    Load(Box<Expr>, i32),
    Addr(String, i64),
    Fp,
    Slot(String),
    Select(Box<Expr>, Box<Expr>, Box<Expr>),
}

#[derive(Debug)]
pub enum Stmt {
    Set(String, Expr),
    Store(Expr, i32, Expr),
    Jump(String),
    Br(Expr, String, String),
    Return(Expr, Expr),
    CallLisp {
        v0: String,
        nv: String,
        entry: Expr,
        args: Vec<Expr>,
        handler: Option<String>,
    },
    CallRt {
        name: String,
        results: Vec<String>,
        args: Vec<Expr>,
        handler: Option<String>,
    },
    Ovf {
        op: OvfOp,
        result: String,
        overflow: String,
        a: Expr,
        b: Expr,
    },
    Trap,
}

/// Variables every function has without declaring them.
pub const PREDEFINED_VARS: &[(&str, VarKind)] = &[
    ("ctx", VarKind::Raw),
    ("self", VarKind::Obj),
    ("nargs", VarKind::Raw),
    ("a0", VarKind::Obj),
    ("a1", VarKind::Obj),
    ("a2", VarKind::Obj),
    ("a3", VarKind::Obj),
    ("exn0", VarKind::Raw),
    ("exn1", VarKind::Obj),
];

/// Number of argument registers in the Lisp calling convention.
pub const REG_ARGS: usize = 4;

type R<T> = Result<T, String>;

fn list(s: &Sexp) -> R<&[Sexp]> {
    match s {
        Sexp::List(v) => Ok(v),
        _ => Err(format!("expected a list, got {s}")),
    }
}

fn sym(s: &Sexp) -> R<&str> {
    match s {
        Sexp::Sym(x) => Ok(x),
        _ => Err(format!("expected a symbol, got {s}")),
    }
}

fn string(s: &Sexp) -> R<&str> {
    match s {
        Sexp::Str(x) => Ok(x),
        _ => Err(format!("expected a string, got {s}")),
    }
}

fn int(s: &Sexp) -> R<i64> {
    match s {
        Sexp::Int(n) => Ok(*n),
        _ => Err(format!("expected an integer, got {s}")),
    }
}

fn head(items: &[Sexp]) -> R<(&str, &[Sexp])> {
    let (h, rest) = items.split_first().ok_or("empty form")?;
    Ok((sym(h)?, rest))
}

fn arity(form: &str, rest: &[Sexp], n: usize) -> R<()> {
    if rest.len() == n {
        Ok(())
    } else {
        Err(format!("{form}: expected {n} operands, got {}", rest.len()))
    }
}

fn handler(s: &Sexp) -> R<Option<String>> {
    let name = sym(s)?;
    Ok(if name == "nil" { None } else { Some(name.to_string()) })
}

pub fn parse_module(s: &Sexp) -> R<Module> {
    let (h, rest) = head(list(s)?)?;
    if h != "module" {
        return Err("expected (module ...)".into());
    }
    let (name, decls) = rest.split_first().ok_or("module: missing name")?;
    let mut m = Module {
        name: string(name)?.to_string(),
        init: String::new(),
        import_funcs: vec![],
        import_data: vec![],
        data: vec![],
        funcs: vec![],
    };
    for d in decls {
        let (h, rest) = head(list(d)?)?;
        match h {
            "init" => {
                arity(h, rest, 1)?;
                m.init = string(&rest[0])?.to_string();
            }
            "import-func" => {
                if rest.len() < 3 {
                    return Err("import-func: expected name, params, returns".into());
                }
                let mut f = ImportFunc {
                    name: string(&rest[0])?.to_string(),
                    params: int(&rest[1])? as usize,
                    returns: int(&rest[2])? as usize,
                    unwinds: false,
                    noreturn: false,
                };
                for flag in &rest[3..] {
                    match sym(flag)? {
                        "unwinds" => f.unwinds = true,
                        "noreturn" => f.noreturn = true,
                        other => return Err(format!("import-func: unknown flag {other}")),
                    }
                }
                m.import_funcs.push(f);
            }
            "import-data" => {
                arity(h, rest, 1)?;
                m.import_data.push(string(&rest[0])?.to_string());
            }
            "data" => {
                arity(h, rest, 2)?;
                let name = string(&rest[0])?.to_string();
                let (kind, items) = head(list(&rest[1])?)?;
                let contents = match kind {
                    "words" => DataContents::Words(items.iter().map(parse_word).collect::<R<_>>()?),
                    "bytes" => {
                        arity(kind, items, 1)?;
                        DataContents::Bytes(string(&items[0])?.as_bytes().to_vec())
                    }
                    _ => return Err(format!("data: unknown contents {kind}")),
                };
                m.data.push(Data { name, contents });
            }
            "func" => m.funcs.push(parse_func(rest)?),
            _ => return Err(format!("unknown module declaration {h}")),
        }
    }
    if m.init.is_empty() {
        return Err("module has no (init ...)".into());
    }
    Ok(m)
}

fn parse_word(s: &Sexp) -> R<Word> {
    match s {
        Sexp::Int(n) => Ok(Word::Int(*n)),
        _ => {
            let (h, rest) = head(list(s)?)?;
            match h {
                "data" => {
                    let addend = if rest.len() > 1 { int(&rest[1])? } else { 0 };
                    Ok(Word::DataAddr(string(&rest[0])?.to_string(), addend))
                }
                "func" => {
                    arity(h, rest, 1)?;
                    Ok(Word::FuncAddr(string(&rest[0])?.to_string()))
                }
                _ => Err(format!("unknown data word {h}")),
            }
        }
    }
}

fn parse_func(rest: &[Sexp]) -> R<Func> {
    let (name, body) = rest.split_first().ok_or("func: missing name")?;
    let mut f = Func {
        name: string(name)?.to_string(),
        vars: vec![],
        slots: vec![],
        blocks: vec![],
    };
    for part in body {
        let (h, items) = head(list(part)?)?;
        match h {
            "vars" => {
                for v in items {
                    let pair = list(v)?;
                    if pair.len() != 2 {
                        return Err(format!("vars: malformed entry {v}"));
                    }
                    let kind = match sym(&pair[1])? {
                        "obj" => VarKind::Obj,
                        "raw" => VarKind::Raw,
                        k => return Err(format!("vars: unknown kind {k}")),
                    };
                    f.vars.push((sym(&pair[0])?.to_string(), kind));
                }
            }
            "slots" => {
                for v in items {
                    let pair = list(v)?;
                    if pair.len() != 2 {
                        return Err(format!("slots: malformed entry {v}"));
                    }
                    f.slots
                        .push((sym(&pair[0])?.to_string(), int(&pair[1])? as u32));
                }
            }
            "block" => {
                let (bname, stmts) = items.split_first().ok_or("block: missing name")?;
                f.blocks.push(Block {
                    name: sym(bname)?.to_string(),
                    stmts: stmts.iter().map(parse_stmt).collect::<R<_>>()?,
                });
            }
            _ => return Err(format!("func {}: unknown part {h}", f.name)),
        }
    }
    if f.blocks.is_empty() {
        return Err(format!("func {} has no blocks", f.name));
    }
    Ok(f)
}

fn parse_stmt(s: &Sexp) -> R<Stmt> {
    let (h, r) = head(list(s)?)?;
    Ok(match h {
        "set" => {
            arity(h, r, 2)?;
            Stmt::Set(sym(&r[0])?.to_string(), parse_expr(&r[1])?)
        }
        "store" => {
            arity(h, r, 3)?;
            Stmt::Store(parse_expr(&r[0])?, int(&r[1])? as i32, parse_expr(&r[2])?)
        }
        "jump" => {
            arity(h, r, 1)?;
            Stmt::Jump(sym(&r[0])?.to_string())
        }
        "br" => {
            arity(h, r, 3)?;
            Stmt::Br(parse_expr(&r[0])?, sym(&r[1])?.to_string(), sym(&r[2])?.to_string())
        }
        "return" => {
            arity(h, r, 2)?;
            Stmt::Return(parse_expr(&r[0])?, parse_expr(&r[1])?)
        }
        "call-lisp" => {
            arity(h, r, 5)?;
            let args: Vec<Expr> = list(&r[3])?.iter().map(parse_expr).collect::<R<_>>()?;
            if args.len() < 3 || args.len() > 3 + REG_ARGS {
                return Err(format!("call-lisp: bad argument count {}", args.len()));
            }
            Stmt::CallLisp {
                v0: sym(&r[0])?.to_string(),
                nv: sym(&r[1])?.to_string(),
                entry: parse_expr(&r[2])?,
                args,
                handler: handler(&r[4])?,
            }
        }
        "call-rt" => {
            arity(h, r, 4)?;
            Stmt::CallRt {
                name: string(&r[0])?.to_string(),
                results: list(&r[1])?
                    .iter()
                    .map(|x| sym(x).map(str::to_string))
                    .collect::<R<_>>()?,
                args: list(&r[2])?.iter().map(parse_expr).collect::<R<_>>()?,
                handler: handler(&r[3])?,
            }
        }
        "add-ovf" | "sub-ovf" | "mul-ovf" => {
            arity(h, r, 4)?;
            Stmt::Ovf {
                op: match h {
                    "add-ovf" => OvfOp::Add,
                    "sub-ovf" => OvfOp::Sub,
                    _ => OvfOp::Mul,
                },
                result: sym(&r[0])?.to_string(),
                overflow: sym(&r[1])?.to_string(),
                a: parse_expr(&r[2])?,
                b: parse_expr(&r[3])?,
            }
        }
        "trap" => {
            arity(h, r, 0)?;
            Stmt::Trap
        }
        _ => return Err(format!("unknown statement {h}")),
    })
}

fn parse_expr(s: &Sexp) -> R<Expr> {
    match s {
        Sexp::Int(n) => return Ok(Expr::Int(*n)),
        Sexp::Sym(v) => return Ok(Expr::Var(v.clone())),
        Sexp::Str(_) => return Err(format!("unexpected string {s}")),
        Sexp::List(_) => {}
    }
    let (h, r) = head(list(s)?)?;
    let e = |i: usize| -> R<Box<Expr>> { Ok(Box::new(parse_expr(&r[i])?)) };
    Ok(match h {
        "add" | "sub" | "mul" | "and" | "or" | "xor" => {
            arity(h, r, 2)?;
            let op = match h {
                "add" => BinOp::Add,
                "sub" => BinOp::Sub,
                "mul" => BinOp::Mul,
                "and" => BinOp::And,
                "or" => BinOp::Or,
                _ => BinOp::Xor,
            };
            Expr::Bin(op, e(0)?, e(1)?)
        }
        "shl" | "sar" | "shr" => {
            arity(h, r, 2)?;
            let op = match h {
                "shl" => ShiftOp::Shl,
                "sar" => ShiftOp::Sar,
                _ => ShiftOp::Shr,
            };
            Expr::Shift(op, e(0)?, int(&r[1])?)
        }
        "eq" | "ne" | "lt" | "le" | "gt" | "ge" => {
            arity(h, r, 2)?;
            let op = match h {
                "eq" => CmpOp::Eq,
                "ne" => CmpOp::Ne,
                "lt" => CmpOp::Lt,
                "le" => CmpOp::Le,
                "gt" => CmpOp::Gt,
                _ => CmpOp::Ge,
            };
            Expr::Cmp(op, e(0)?, e(1)?)
        }
        "load" => {
            arity(h, r, 2)?;
            Expr::Load(e(0)?, int(&r[1])? as i32)
        }
        "addr" => {
            let addend = if r.len() > 1 { int(&r[1])? } else { 0 };
            Expr::Addr(string(&r[0])?.to_string(), addend)
        }
        "fp" => {
            arity(h, r, 0)?;
            Expr::Fp
        }
        "slot" => {
            arity(h, r, 1)?;
            Expr::Slot(sym(&r[0])?.to_string())
        }
        "select" => {
            arity(h, r, 3)?;
            Expr::Select(e(0)?, e(1)?, e(2)?)
        }
        _ => return Err(format!("unknown expression {h}")),
    })
}
