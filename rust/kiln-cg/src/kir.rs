//! KIR: kiln's low-level IR, the interchange format between the Lisp
//! compiler and this code generator.
//!
//! KIR is close to Cranelift IR but uses mutable variables instead of SSA
//! values and block parameters; cranelift-frontend builds the SSA form.

use crate::sexp::Sexp;

#[derive(Debug)]
pub struct Module {
    pub name: String,
    /// Init function objects, run in order. One per source KIR module.
    pub inits: Vec<String>,
    /// Data and functions that several modules may define identically
    /// (symbols and what belongs to them): only the first is kept.
    pub shared: std::collections::HashSet<String>,
    pub import_funcs: Vec<ImportFunc>,
    pub import_data: Vec<String>,
    pub data: Vec<Data>,
    /// Static GC roots: (data name, word index).
    pub roots: Vec<(String, u32)>,
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

#[derive(Debug, Clone)]
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
    /// Variables that hold a source variable: (variable, index of its
    /// name in the function's debug info).
    pub labels: Vec<(String, u32)>,
    pub slots: Vec<(String, u32)>,
    pub blocks: Vec<Block>,
    /// The function's debug info object.
    pub debug: Option<DebugRef>,
}

/// Where a function's debug info object is.
#[derive(Debug, Clone)]
pub enum DebugRef {
    /// The object itself, a static object: `(debug WORD)`.
    Direct(Word),
    /// The address of a word holding the object: `(debug-ref "data"
    /// offset)`, for code compiled into the running image, whose objects
    /// are literals.
    Indirect(String, i64),
}

/// A source range: start and end offsets in the file of the function.
pub type Loc = (u32, u32);

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
    /// Signed division and remainder, truncating; the divisor must not be
    /// 0, and not -1 with i64::MIN as the dividend.
    Sdiv,
    Srem,
    /// Shifts by a count in a value, which must be in 0..64.
    Shlv,
    Sarv,
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
    /// Zero-extended 32-bit load.
    Load32(Box<Expr>, i32),
    Addr(String, i64),
    Fp,
    Slot(String),
    Select(Box<Expr>, Box<Expr>, Box<Expr>),
}

#[derive(Debug)]
pub enum Stmt {
    Set(String, Expr),
    Store(Expr, i32, Expr),
    /// Stores the low 32 bits.
    Store32(Expr, i32, Expr),
    Jump(String),
    Br(Expr, String, String),
    Return(Expr, Expr),
    CallLisp {
        v0: String,
        nv: String,
        entry: Expr,
        args: Vec<Expr>,
        handler: Option<String>,
        loc: Option<Loc>,
    },
    CallRt {
        name: String,
        results: Vec<String>,
        args: Vec<Expr>,
        handler: Option<String>,
        loc: Option<Loc>,
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
    ("exn0", VarKind::Raw),
    ("exn1", VarKind::Obj),
];

/// Number of argument registers in the Lisp calling convention. With ctx,
/// self and nargs this keeps every argument in a register on x86-64, which
/// the GC stack walk relies on (see kiln-rt gc.rs).
pub const REG_ARGS: usize = 3;

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

/// An optional `(loc START END)` after a call's operands.
fn loc(form: &str, rest: &[Sexp], n: usize) -> R<Option<Loc>> {
    match rest.len() {
        len if len == n => Ok(None),
        len if len == n + 1 => {
            let (h, r) = head(list(&rest[n])?)?;
            if h != "loc" || r.len() != 2 {
                return Err(format!("{form}: expected (loc START END), got {}", rest[n]));
            }
            Ok(Some((int(&r[0])? as u32, int(&r[1])? as u32)))
        }
        len => Err(format!("{form}: expected {n} operands, got {len}")),
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
        inits: vec![],
        shared: Default::default(),
        import_funcs: vec![],
        import_data: vec![],
        data: vec![],
        roots: vec![],
        funcs: vec![],
    };
    for d in decls {
        let (h, rest) = head(list(d)?)?;
        match h {
            "init" => {
                arity(h, rest, 1)?;
                m.inits.push(string(&rest[0])?.to_string());
            }
            "shared" => {
                for n in rest {
                    m.shared.insert(string(n)?.to_string());
                }
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
            "root" => {
                arity(h, rest, 2)?;
                m.roots.push((string(&rest[0])?.to_string(), int(&rest[1])? as u32));
            }
            "func" => m.funcs.push(parse_func(rest)?),
            _ => return Err(format!("unknown module declaration {h}")),
        }
    }
    if m.inits.is_empty() {
        return Err("module has no (init ...)".into());
    }
    Ok(m)
}

/// Combines KIR modules into one, in order: their init functions run in
/// that order. Shared data and functions are kept once; any other name
/// defined twice is an error.
pub fn merge(modules: Vec<Module>) -> R<Module> {
    let mut out = Module {
        name: modules.iter().map(|m| m.name.as_str()).collect::<Vec<_>>().join("+"),
        inits: vec![],
        shared: Default::default(),
        import_funcs: vec![],
        import_data: vec![],
        data: vec![],
        roots: vec![],
        funcs: vec![],
    };
    let mut defined = std::collections::HashSet::new();
    let mut imported = std::collections::HashSet::new();
    let mut roots = std::collections::HashSet::new();
    for m in modules {
        out.inits.extend(m.inits);
        for f in m.import_funcs {
            if imported.insert(f.name.clone()) {
                out.import_funcs.push(f);
            }
        }
        for d in m.import_data {
            if imported.insert(d.clone()) {
                out.import_data.push(d);
            }
        }
        for d in m.data {
            if defined.insert(d.name.clone()) {
                out.data.push(d);
            } else if !m.shared.contains(&d.name) {
                return Err(format!("data {} is defined by two modules", d.name));
            }
        }
        for f in m.funcs {
            if defined.insert(f.name.clone()) {
                out.funcs.push(f);
            } else if !m.shared.contains(&f.name) {
                return Err(format!("function {} is defined by two modules", f.name));
            }
        }
        for r in m.roots {
            if roots.insert(r.clone()) {
                out.roots.push(r);
            }
        }
        out.shared.extend(m.shared);
    }
    Ok(out)
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
        labels: vec![],
        slots: vec![],
        blocks: vec![],
        debug: None,
    };
    for part in body {
        let (h, items) = head(list(part)?)?;
        match h {
            "vars" => {
                for v in items {
                    let pair = list(v)?;
                    if pair.len() != 2 && pair.len() != 3 {
                        return Err(format!("vars: malformed entry {v}"));
                    }
                    let kind = match sym(&pair[1])? {
                        "obj" => VarKind::Obj,
                        "raw" => VarKind::Raw,
                        k => return Err(format!("vars: unknown kind {k}")),
                    };
                    let name = sym(&pair[0])?.to_string();
                    if pair.len() == 3 {
                        f.labels.push((name.clone(), int(&pair[2])? as u32));
                    }
                    f.vars.push((name, kind));
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
            "debug" => {
                arity(h, items, 1)?;
                f.debug = Some(DebugRef::Direct(parse_word(&items[0])?));
            }
            "debug-ref" => {
                arity(h, items, 2)?;
                f.debug = Some(DebugRef::Indirect(string(&items[0])?.to_string(), int(&items[1])?));
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
        "store32" => {
            arity(h, r, 3)?;
            Stmt::Store32(parse_expr(&r[0])?, int(&r[1])? as i32, parse_expr(&r[2])?)
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
            let loc = loc(h, r, 5)?;
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
                loc,
            }
        }
        "call-rt" => {
            let loc = loc(h, r, 4)?;
            Stmt::CallRt {
                name: string(&r[0])?.to_string(),
                results: list(&r[1])?
                    .iter()
                    .map(|x| sym(x).map(str::to_string))
                    .collect::<R<_>>()?,
                args: list(&r[2])?.iter().map(parse_expr).collect::<R<_>>()?,
                handler: handler(&r[3])?,
                loc,
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
        "add" | "sub" | "mul" | "and" | "or" | "xor" | "sdiv" | "srem" | "shlv" | "sarv" => {
            arity(h, r, 2)?;
            let op = match h {
                "add" => BinOp::Add,
                "sub" => BinOp::Sub,
                "mul" => BinOp::Mul,
                "and" => BinOp::And,
                "or" => BinOp::Or,
                "sdiv" => BinOp::Sdiv,
                "srem" => BinOp::Srem,
                "shlv" => BinOp::Shlv,
                "sarv" => BinOp::Sarv,
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
        "load32" => {
            arity(h, r, 2)?;
            Expr::Load32(e(0)?, int(&r[1])? as i32)
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
