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
    /// Unboxed binary64, spilled at safepoints for debugging but not traced.
    F64,
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
    /// IEEE binary64 operations on unboxed bit patterns.
    F64Add,
    F64Sub,
    F64Mul,
    F64Div,
    /// Three-way comparison; unordered operands compare as equal.
    F64Compare,
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

#[derive(Debug, Clone)]
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
    Switch(Expr, String, Vec<(i64, String)>),
    Return(Expr, Expr),
    CallLisp {
        v0: String,
        nv: String,
        entry: Expr,
        args: Vec<Expr>,
        handler: Option<String>,
        loc: Option<Loc>,
    },
    /// A call in tail position: the callee's values are this function's.
    /// Only where nothing of this frame is needed after the call: no
    /// dynamic-environment entry (catch, unwind-protect, special binding)
    /// of the function may be active.
    TailCallLisp {
        entry: Expr,
        args: Vec<Expr>,
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
                    _ => DataContents::Words(parse_static_object(kind, items)?),
                };
                m.data.push(Data { name, contents });
            }
            "root" => {
                arity(h, rest, 2)?;
                m.roots.push((string(&rest[0])?.to_string(), int(&rest[1])? as u32));
            }
            "symbol-roots" => {
                let (name, fields) = rest.split_first().ok_or("symbol-roots: missing name")?;
                let name = string(name)?.to_string();
                for field in fields {
                    let field = u32::try_from(int(field)?).map_err(|_| "invalid symbol root field")?;
                    m.roots.push((name.clone(), crate::lir::symbol_root_index(field)?));
                }
            }
            "field-root" => {
                arity(h, rest, 2)?;
                let field = u32::try_from(int(&rest[1])?).map_err(|_| "invalid root field")?;
                m.roots.push((string(&rest[0])?.to_string(), crate::lir::static_field_root_index(field)?));
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
                    if rest.len() != 1 && rest.len() != 2 { return Err("data word: expected name and optional addend".into()); }
                    let addend = if rest.len() > 1 { int(&rest[1])? } else { 0 };
                    Ok(Word::DataAddr(string(&rest[0])?.to_string(), addend))
                }
                "object-data" => {
                    arity(h, rest, 2)?;
                    Ok(Word::DataAddr(string(&rest[0])?.to_string(), crate::lir::static_object_tag(sym(&rest[1])?)?))
                }
                "fixnum" => {
                    arity(h, rest, 1)?;
                    let value = int(&rest[0])?;
                    if !(-(1_i64 << 62)..(1_i64 << 62)).contains(&value) {
                        return Err("fixnum out of range".into());
                    }
                    Ok(Word::Int(value << 1))
                }
                "character" => {
                    arity(h, rest, 1)?;
                    let code = int(&rest[0])?;
                    if !(0..0x110000).contains(&code) { return Err("character code out of range".into()); }
                    Ok(Word::Int((code << kiln_rt::object::CHARACTER_SHIFT) | kiln_rt::object::CHARACTER_TAG as i64))
                }
                "single-float" => {
                    arity(h, rest, 1)?;
                    let bits = u32::try_from(int(&rest[0])?).map_err(|_| "single-float bits out of range")?;
                    Ok(Word::Int((((bits as u64) << 32) | kiln_rt::number::SINGLE_TAG) as i64))
                }
                "func" => {
                    arity(h, rest, 1)?;
                    Ok(Word::FuncAddr(string(&rest[0])?.to_string()))
                }
                "unbound" => {
                    arity(h, rest, 0)?;
                    Ok(Word::Int(kiln_rt::object::UNBOUND as i64))
                }
                _ => Err(format!("unknown data word {h}")),
            }
        }
    }
}

fn parse_static_object(kind: &str, items: &[Sexp]) -> R<Vec<Word>> {
    use kiln_rt::object::*;
    let header = |kind: u64, length: usize| -> R<Word> {
        let length = u64::try_from(length).map_err(|_| "static object length out of range")?;
        if length > LENGTH_MASK { return Err("static object length out of range".into()); }
        Ok(Word::Int((kind | (length << LENGTH_SHIFT)) as i64))
    };
    match kind {
        "static-symbol" => {
            arity(kind, items, 6)?;
            let mut words = vec![Word::Int(0); size_of::<SymbolObj>() / size_of::<u64>()];
            words[core::mem::offset_of!(SymbolObj, header) / size_of::<u64>()] = Word::Int(KIND_SYMBOL as i64);
            for (offset, value) in [
                (core::mem::offset_of!(SymbolObj, name), &items[0]),
                (core::mem::offset_of!(SymbolObj, package), &items[1]),
                (core::mem::offset_of!(SymbolObj, function), &items[2]),
                (core::mem::offset_of!(SymbolObj, value), &items[3]),
                (core::mem::offset_of!(SymbolObj, plist), &items[4]),
                (core::mem::offset_of!(SymbolObj, setf_function), &items[5]),
            ] {
                words[offset / size_of::<u64>()] = parse_word(value)?;
            }
            Ok(words)
        }
        "static-function" => {
            let (entry, captures) = items.split_first().ok_or("static-function: missing entry")?;
            let mut words = vec![header(KIND_FUNCTION, captures.len())?, Word::FuncAddr(string(entry)?.to_string())];
            words.extend(captures.iter().map(parse_word).collect::<R<Vec<_>>>()?);
            Ok(words)
        }
        "static-string" => {
            let mut words = vec![header(KIND_STRING, items.len())?];
            for pair in items.chunks(2) {
                let lo = u32::try_from(int(&pair[0])?).map_err(|_| "invalid string code point")?;
                let hi = if pair.len() == 2 { u32::try_from(int(&pair[1])?).map_err(|_| "invalid string code point")? } else { 0 };
                if lo >= 0x110000 || hi >= 0x110000 { return Err("invalid string code point".into()); }
                words.push(Word::Int((u64::from(lo) | (u64::from(hi) << 32)) as i64));
            }
            Ok(words)
        }
        "static-vector" | "static-bignum" => {
            let object_kind = if kind == "static-vector" { KIND_SIMPLE_VECTOR } else { KIND_BIGNUM };
            let mut words = vec![header(object_kind, items.len())?];
            if kind == "static-bignum" {
                words.extend(items.iter().map(|word| int(word).map(Word::Int)).collect::<R<Vec<_>>>()?);
            } else {
                words.extend(items.iter().map(parse_word).collect::<R<Vec<_>>>()?);
            }
            Ok(words)
        }
        "static-cons" | "static-ratio" | "static-complex" => {
            arity(kind, items, 2)?;
            let object_kind = match kind { "static-cons" => KIND_CONS, "static-ratio" => KIND_RATIO, _ => KIND_COMPLEX };
            Ok(vec![Word::Int(object_kind as i64), parse_word(&items[0])?, parse_word(&items[1])?])
        }
        "static-double" => {
            arity(kind, items, 1)?;
            Ok(vec![Word::Int(KIND_DOUBLE as i64), Word::Int(int(&items[0])?)])
        }
        _ => Err(format!("data: unknown contents {kind}")),
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
    fn uses_prefix(value: &Sexp, prefix: &str) -> bool {
        match value {
            Sexp::Sym(s) => s.starts_with(prefix),
            Sexp::List(xs) => xs.iter().any(|x| uses_prefix(x, prefix)),
            _ => false,
        }
    }
    fn validate_stack_references(value: &Sexp, objects: &std::collections::HashMap<String, (u32, i64)>) -> R<()> {
        if let Sexp::List(items) = value {
            if let Some(Sexp::Sym(name)) = items.first() {
                if name == "stack-reference-base" {
                    let args = &items[1..];
                    arity(name, args, 3)?;
                    let slot = sym(&args[0])?;
                    let class = u32::try_from(int(&args[1])?).map_err(|_| "invalid stack object class")?;
                    let count = int(&args[2])?;
                    if objects.get(slot) != Some(&(class, count)) {
                        return Err("stack reference base does not match slot".into());
                    }
                }
            }
            for item in items { validate_stack_references(item, objects)?; }
        }
        Ok(())
    }
    let mut prefix = "__kiln_lir_".to_string();
    while body.iter().any(|part| uses_prefix(part, &prefix)) {
        prefix.push('_');
    }
    let mut alloc_number = 0usize;
    let mut stack_objects = std::collections::HashMap::new();
    let mut stack_root_entries = std::collections::HashSet::new();
    let mut dynamic_entries = std::collections::HashMap::new();
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
                        "f64" => VarKind::F64,
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
                    let name = sym(&pair[0])?.to_string();
                    let size = match &pair[1] {
                        Sexp::Int(n) => u32::try_from(*n).map_err(|_| "invalid slot size")?,
                        descriptor => {
                            let (kind, args) = head(list(descriptor)?)?;
                            if kind == "stack-roots-entry" {
                                arity(kind, args, 0)?;
                                if !stack_root_entries.insert(name.clone()) { return Err("duplicate stack roots entry".into()); }
                                f.slots.push((name, core::mem::size_of::<kiln_rt::context::DynEntry>() as u32));
                                continue;
                            }
                            if kind == "dynamic-entry" {
                                arity(kind, args, 1)?;
                                let entry_kind = sym(&args[0])?;
                                crate::lir::dynamic_entry_kind(entry_kind)?;
                                if dynamic_entries.insert(name.clone(), entry_kind.to_string()).is_some() { return Err("duplicate dynamic entry".into()); }
                                f.slots.push((name, core::mem::size_of::<kiln_rt::context::DynEntry>() as u32));
                                continue;
                            }
                            if kind != "stack-object" { return Err("unknown slot descriptor".into()); }
                            arity(kind, args, 2)?;
                            let class = u32::try_from(int(&args[0])?).map_err(|_| "invalid stack object class")?;
                            let count = int(&args[1])?;
                            let (size, _, _) = crate::lir::stack_object_layout(class, count)?;
                            if stack_objects.insert(name.clone(), (class, count)).is_some() { return Err("duplicate stack object slot".into()); }
                            size
                        }
                    };
                    f.slots.push((name, size));
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
                let mut block_name = sym(bname)?.to_string();
                let mut lowered = Vec::new();
                for stmt in stmts {
                    validate_stack_references(stmt, &stack_objects)?;
                    let (head_name, operands) = head(list(stmt)?)?;
                    if head_name == "heap-number-p" {
                        arity(head_name, operands, 2)?;
                        let result = sym(&operands[0])?.to_string();
                        let object = sym(&operands[1])?.to_string();
                        if result == object { return Err("heap-number-p result must differ from object".into()); }
                        let temp = format!("{prefix}{alloc_number}_kind");
                        alloc_number += 1;
                        f.vars.push((temp.clone(), VarKind::Raw));
                        lowered.extend(crate::lir::heap_number_test(result, temp, Expr::Var(object)));
                        continue;
                    }
                    if head_name == "identity-hash" {
                        arity(head_name, operands, 3)?;
                        let result = sym(&operands[0])?.to_string();
                        let object = sym(&operands[1])?.to_string();
                        if result == object { return Err("identity-hash result must differ from object".into()); }
                        let name = format!("{prefix}{alloc_number}");
                        alloc_number += 1;
                        let (vars, blocks, next_name) = crate::lir::identity_hash(&name, block_name, lowered, result, object, string(&operands[2])?.to_string());
                        f.vars.extend(vars);
                        f.blocks.extend(blocks);
                        block_name = next_name;
                        lowered = Vec::new();
                        continue;
                    }
                    if head_name == "ensure-tls-index" {
                        arity(head_name, operands, 3)?;
                        let result = sym(&operands[0])?.to_string();
                        let symbol = sym(&operands[1])?.to_string();
                        if result == symbol { return Err("ensure-tls-index result must differ from symbol".into()); }
                        let name = format!("{prefix}{alloc_number}");
                        alloc_number += 1;
                        let (blocks, next_name) = crate::lir::ensure_tls_index(&name, block_name, lowered, result, symbol, string(&operands[2])?.to_string())?;
                        f.blocks.extend(blocks);
                        block_name = next_name;
                        lowered = Vec::new();
                        continue;
                    }
                    if head_name == "special-ref" || head_name == "special-set" {
                        arity(head_name, operands, 2)?;
                        let (result, symbol, value) = if head_name == "special-ref" {
                            let result = sym(&operands[0])?.to_string();
                            let symbol = sym(&operands[1])?.to_string();
                            if result == symbol { return Err("special-ref result must differ from symbol".into()); }
                            (Some(result), symbol, None)
                        } else {
                            let symbol = sym(&operands[0])?.to_string();
                            let value = parse_expr(&operands[1])?;
                            if !matches!(value, Expr::Var(_) | Expr::Int(_)) { return Err("special-set requires a stable value".into()); }
                            (None, symbol, Some(value))
                        };
                        let name = format!("{prefix}{alloc_number}");
                        alloc_number += 1;
                        let (vars, blocks, next_name) = crate::lir::special_access(&name, block_name, lowered, symbol, result, value)?;
                        f.vars.extend(vars);
                        f.blocks.extend(blocks);
                        block_name = next_name;
                        lowered = Vec::new();
                        continue;
                    }
                    if head_name == "special-bind" || head_name == "special-bind-index" || head_name == "special-unbind" {
                        arity(head_name, operands, match head_name { "special-bind" => 4, "special-bind-index" => 3, _ => 1 })?;
                        let entry = sym(&operands[0])?;
                        if dynamic_entries.get(entry).map(String::as_str) != Some("bind") { return Err("special binding operation requires a bind entry".into()); }
                        if head_name == "special-bind" {
                            let index = parse_expr(&operands[1])?;
                            let address = parse_expr(&operands[2])?;
                            let value = parse_expr(&operands[3])?;
                            if [&index, &address, &value].iter().any(|operand| !matches!(operand, Expr::Var(_) | Expr::Int(_))) {
                                return Err("special-bind requires stable operands".into());
                            }
                            lowered.extend(crate::lir::bind_special(entry.to_string(), index, address, value));
                        } else if head_name == "special-bind-index" {
                            let index = parse_expr(&operands[1])?;
                            let value = parse_expr(&operands[2])?;
                            if [&index, &value].iter().any(|operand| !matches!(operand, Expr::Var(_) | Expr::Int(_))) {
                                return Err("special-bind-index requires stable operands".into());
                            }
                            let temporary = format!("{prefix}{alloc_number}_tls");
                            alloc_number += 1;
                            f.vars.push((temporary.clone(), VarKind::Raw));
                            lowered.extend(crate::lir::bind_special_index(entry.to_string(), temporary, index, value));
                        } else {
                            lowered.push(crate::lir::unbind_special(entry.to_string()));
                        }
                        continue;
                    }
                    if head_name == "progv-bindings" {
                        arity(head_name, operands, 2)?;
                        let result = sym(&operands[0])?;
                        let entry = sym(&operands[1])?;
                        if dynamic_entries.get(entry).map(String::as_str) != Some("progv") { return Err("progv-bindings requires a progv entry".into()); }
                        lowered.push(crate::lir::progv_bindings(result.to_string(), entry.to_string()));
                        continue;
                    }
                    if head_name == "dynamic-relink" {
                        arity(head_name, operands, 1)?;
                        let entry = sym(&operands[0])?;
                        if dynamic_entries.get(entry).map(String::as_str) != Some("exit-point") { return Err("dynamic-relink requires an exit-point entry".into()); }
                        lowered.push(crate::lir::relink_dynamic_entry(entry.to_string()));
                        continue;
                    }
                    if head_name == "dynamic-enter" {
                        arity(head_name, operands, 3)?;
                        let entry = sym(&operands[0])?;
                        let kind = sym(&operands[1])?;
                        if dynamic_entries.get(entry).map(String::as_str) != Some(kind) {
                            return Err("dynamic-enter does not match entry slot".into());
                        }
                        lowered.extend(crate::lir::enter_dynamic_entry(entry.to_string(), kind, parse_expr(&operands[2])?)?);
                        continue;
                    }
                    if head_name == "dynamic-leave" {
                        arity(head_name, operands, 1)?;
                        let entry = sym(&operands[0])?;
                        if !dynamic_entries.contains_key(entry) { return Err("dynamic-leave requires a dynamic entry".into()); }
                        lowered.push(crate::lir::leave_dynamic_entry(entry.to_string()));
                        continue;
                    }
                    if head_name == "stack-roots-enter" {
                        arity(head_name, operands, 4)?;
                        let entry = sym(&operands[0])?;
                        let slot = sym(&operands[1])?;
                        let class = u32::try_from(int(&operands[2])?).map_err(|_| "invalid stack object class")?;
                        let count = int(&operands[3])?;
                        if !stack_root_entries.contains(entry) || stack_objects.get(slot) != Some(&(class, count)) || count <= 0 {
                            return Err("stack-roots-enter requires matching entry and object slots".into());
                        }
                        lowered.extend(crate::lir::enter_stack_roots(entry.to_string(), slot.to_string(), class, count)?);
                        continue;
                    }
                    if head_name == "stack-roots-leave" {
                        arity(head_name, operands, 1)?;
                        let entry = sym(&operands[0])?;
                        if !stack_root_entries.contains(entry) { return Err("stack-roots-leave requires a roots entry".into()); }
                        lowered.push(crate::lir::leave_dynamic_entry(entry.to_string()));
                        continue;
                    }
                    if head_name == "stack-closure" {
                        arity(head_name, operands, 3)?;
                        let result = sym(&operands[0])?.to_string();
                        let slot = sym(&operands[1])?;
                        if !matches!(stack_objects.get(slot), Some((crate::packet::schema::CLASS_FUNCTION, _))) {
                            return Err("stack-closure requires a closure slot".into());
                        }
                        lowered.extend(crate::lir::initialize_stack_closure(result, slot.to_string(), string(&operands[2])?.to_string()));
                        continue;
                    }
                    if head_name == "stack-cons" {
                        arity(head_name, operands, 4)?;
                        let result = sym(&operands[0])?.to_string();
                        let address = parse_expr(&operands[1])?;
                        match &address {
                            Expr::Slot(slot) if stack_objects.get(slot) == Some(&(crate::packet::schema::CLASS_CONS, 2)) => (),
                            Expr::Var(name) if name != &result => (),
                            _ => return Err("stack-cons requires a cons slot or a stable address variable".into()),
                        }
                        let car = parse_expr(&operands[2])?;
                        let cdr = parse_expr(&operands[3])?;
                        if !matches!(car, Expr::Var(_) | Expr::Int(_)) || !matches!(cdr, Expr::Var(_) | Expr::Int(_)) {
                            return Err("stack-cons fields must be stable operands".into());
                        }
                        lowered.extend(crate::lir::initialize_stack_cons(result, address, car, cdr));
                        continue;
                    }
                    if head_name == "stack-object-init" {
                        arity(head_name, operands, 3)?;
                        let slot = sym(&operands[0])?;
                        let class = u32::try_from(int(&operands[1])?).map_err(|_| "invalid stack object class")?;
                        let count = int(&operands[2])?;
                        if stack_objects.get(slot) != Some(&(class, count)) { return Err("stack object initialization does not match slot".into()); }
                        lowered.extend(crate::lir::initialize_stack_object(slot.to_string(), class, count)?);
                        continue;
                    }
                    if head_name == "alloc-symbol" {
                        arity(head_name, operands, 5)?;
                        let result = sym(&operands[0])?.to_string();
                        let name_value = parse_expr(&operands[1])?;
                        let nil_value = parse_expr(&operands[2])?;
                        for operand in [&name_value, &nil_value] {
                            match operand {
                                Expr::Int(_) => (),
                                Expr::Var(name) if name != &result => (),
                                _ => return Err("alloc-symbol requires stable operands distinct from the result".into()),
                            }
                        }
                        let name = format!("{prefix}{alloc_number}");
                        alloc_number += 1;
                        let raw = format!("{name}_object");
                        f.vars.push((raw.clone(), VarKind::Raw));
                        let (vars, blocks, next_name, mut next_stmts) = crate::lir::allocate_raw(
                            &name, block_name, lowered, raw.clone(), Expr::Int(kiln_rt::object::SYMBOL_BYTES as i64),
                            Expr::Int(kiln_rt::object::KIND_SYMBOL as i64), true,
                            string(&operands[3])?.to_string(), handler(&operands[4])?,
                        )?;
                        f.vars.extend(vars);
                        f.blocks.extend(blocks);
                        next_stmts.extend(crate::lir::initialize_symbol(result, raw, name_value, nil_value));
                        block_name = next_name;
                        lowered = next_stmts;
                        continue;
                    }
                    if head_name == "alloc-structure" || head_name == "alloc-rack" {
                        arity(head_name, operands, 5)?;
                        let result = sym(&operands[0])?.to_string();
                        let layout = parse_expr(&operands[1])?;
                        let count = parse_expr(&operands[2])?;
                        for operand in [&layout, &count] {
                            match operand {
                                Expr::Int(_) => (),
                                Expr::Var(name) if name != &result => (),
                                _ => return Err("alloc-structure requires stable operands distinct from the result".into()),
                            }
                        }
                        let (bytes, header) = if head_name == "alloc-rack" {
                            crate::lir::rack_allocation_layout(&count)?
                        } else {
                            crate::lir::structure_allocation_layout(&count)?
                        };
                        let name = format!("{prefix}{alloc_number}");
                        alloc_number += 1;
                        let raw = format!("{name}_object");
                        f.vars.push((raw.clone(), VarKind::Raw));
                        let (vars, blocks, next_name, mut next_stmts) = crate::lir::allocate_raw(
                            &name, block_name, lowered, raw.clone(), bytes, header, true,
                            string(&operands[3])?.to_string(), handler(&operands[4])?,
                        )?;
                        f.vars.extend(vars);
                        f.blocks.extend(blocks);
                        next_stmts.extend(crate::lir::initialize_structure(result, raw, layout));
                        block_name = next_name;
                        lowered = next_stmts;
                        continue;
                    }
                    if head_name == "alloc-closure" {
                        arity(head_name, operands, 5)?;
                        let result = sym(&operands[0])?.to_string();
                        let entry = string(&operands[1])?.to_string();
                        let (bytes, header) = crate::lir::closure_layout(int(&operands[2])?)?;
                        let name = format!("{prefix}{alloc_number}");
                        alloc_number += 1;
                        let raw = format!("{name}_object");
                        f.vars.push((raw.clone(), VarKind::Raw));
                        let (vars, blocks, next_name, mut next_stmts) = crate::lir::allocate_raw(
                            &name, block_name, lowered, raw.clone(), Expr::Int(bytes), Expr::Int(header), true,
                            string(&operands[3])?.to_string(), handler(&operands[4])?,
                        )?;
                        f.vars.extend(vars);
                        f.blocks.extend(blocks);
                        next_stmts.extend(crate::lir::initialize_closure(result, raw, entry));
                        block_name = next_name;
                        lowered = next_stmts;
                        continue;
                    }
                    if head_name == "alloc-vector-elements" {
                        arity(head_name, operands, 4)?;
                        let result = sym(&operands[0])?.to_string();
                        let values = list(&operands[1])?.iter().map(parse_expr).collect::<R<Vec<_>>>()?;
                        for value in &values {
                            match value {
                                Expr::Int(_) => (),
                                Expr::Var(name) if name != &result => (),
                                _ => return Err("alloc-vector-elements: elements must be stable operands distinct from the result".into()),
                            }
                        }
                        let length = i64::try_from(values.len()).map_err(|_| "vector length out of range")?;
                        let (bytes, header, _) = crate::lir::vector_layout(crate::packet::schema::CLASS_SIMPLE_VECTOR, &Expr::Int(length))?;
                        let name = format!("{prefix}{alloc_number}");
                        alloc_number += 1;
                        let raw = format!("{name}_object");
                        f.vars.push((raw.clone(), VarKind::Raw));
                        let (vars, blocks, next_name, mut next_stmts) = crate::lir::allocate_raw(
                            &name, block_name, lowered, raw.clone(), bytes, header, false,
                            string(&operands[2])?.to_string(), handler(&operands[3])?,
                        )?;
                        f.vars.extend(vars);
                        f.blocks.extend(blocks);
                        next_stmts.extend(crate::lir::initialize_vector_elements(result, raw, values));
                        block_name = next_name;
                        lowered = next_stmts;
                        continue;
                    }
                    if head_name == "alloc-vector" {
                        arity(head_name, operands, 6)?;
                        let result = sym(&operands[0])?.to_string();
                        let class = u32::try_from(int(&operands[1])?).map_err(|_| "invalid allocation class")?;
                        let length = parse_expr(&operands[2])?;
                        let value = parse_expr(&operands[3])?;
                        for operand in [&length, &value] {
                            match operand {
                                Expr::Int(_) => (),
                                Expr::Var(name) if name != &result => (),
                                _ => return Err("alloc-vector: length and value must be stable operands distinct from the result".into()),
                            }
                        }
                        let (bytes, header, shift) = crate::lir::vector_layout(class, &length)?;
                        let name = format!("{prefix}{alloc_number}");
                        alloc_number += 1;
                        let raw = format!("{name}_object");
                        f.vars.push((raw.clone(), VarKind::Raw));
                        let zero = shift == 2 || matches!(value, Expr::Int(0));
                        let (vars, blocks, next_name, next_stmts) = crate::lir::allocate_raw(
                            &name, block_name, lowered, raw.clone(), bytes, header, zero,
                            string(&operands[4])?.to_string(), handler(&operands[5])?,
                        )?;
                        f.vars.extend(vars);
                        f.blocks.extend(blocks);
                        let (vars, blocks, next_name, next_stmts) = crate::lir::initialize_vector(
                            &name, next_name, next_stmts, result, raw, length, value, shift,
                        );
                        f.vars.extend(vars);
                        f.blocks.extend(blocks);
                        block_name = next_name;
                        lowered = next_stmts;
                        continue;
                    }
                    if head_name == "alloc-raw" || head_name == "alloc-cons" || head_name == "alloc-fixed" {
                        arity(head_name, operands, if head_name == "alloc-raw" { 6 } else { 5 })?;
                        let result = sym(&operands[0])?.to_string();
                        let name = format!("{prefix}{alloc_number}");
                        alloc_number += 1;
                        let (raw_result, bytes, header, zero, runtime, handler, fields) =
                            if head_name != "alloc-raw" {
                                let (class, values) = if head_name == "alloc-cons" {
                                    (crate::packet::schema::CLASS_CONS, vec![parse_expr(&operands[1])?, parse_expr(&operands[2])?])
                                } else {
                                    let class = u32::try_from(int(&operands[1])?).map_err(|_| "invalid allocation class")?;
                                    (class, list(&operands[2])?.iter().map(parse_expr).collect::<R<Vec<_>>>()?)
                                };
                                let (bytes, header, _, count) = crate::lir::fixed_layout(class)?;
                                if values.len() != count { return Err("fixed allocation: wrong field count".into()); }
                                for value in &values {
                                    match value {
                                        Expr::Int(_) => (),
                                        Expr::Var(name) if name != &result => (),
                                        _ => return Err("fixed allocation: fields must be stable operands distinct from the result".into()),
                                    }
                                }
                                let raw = format!("{name}_object");
                                f.vars.push((raw.clone(), VarKind::Raw));
                                (raw, Expr::Int(bytes), Expr::Int(header), false,
                                 string(&operands[3])?.to_string(), handler(&operands[4])?, Some((class, values)))
                            } else {
                                let zero = match int(&operands[3])? {
                                    0 => false, 1 => true,
                                    _ => return Err("alloc-raw: invalid zero flag".into()),
                                };
                                (result.clone(), parse_expr(&operands[1])?, parse_expr(&operands[2])?, zero,
                                 string(&operands[4])?.to_string(), handler(&operands[5])?, None)
                            };
                        let (vars, blocks, next_name, next_stmts) = crate::lir::allocate_raw(
                            &name, block_name, lowered, raw_result.clone(), bytes, header, zero, runtime, handler,
                        )?;
                        f.vars.extend(vars);
                        f.blocks.extend(blocks);
                        block_name = next_name;
                        lowered = next_stmts;
                        if let Some((class, values)) = fields {
                            lowered.extend(crate::lir::initialize_fixed(result, raw_result, class, values)?);
                        }
                    } else {
                        lowered.extend(parse_statements(stmt)?);
                    }
                }
                f.blocks.push(Block {
                    name: block_name,
                    stmts: lowered,
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

fn parse_statements(s: &Sexp) -> R<Vec<Stmt>> {
    let (h, r) = head(list(s)?)?;
    if h != "invoke" {
        return Ok(vec![parse_stmt(s)?]);
    }
    let location = loc(h, r, 5)?;
    crate::lir::invoke(
        sym(&r[0])?.to_string(), sym(&r[1])?.to_string(), sym(&r[2])?.to_string(),
        list(&r[3])?.iter().map(parse_expr).collect::<R<_>>()?, handler(&r[4])?, location,
    )
}

fn parse_stmt(s: &Sexp) -> R<Stmt> {
    let (h, r) = head(list(s)?)?;
    Ok(match h {
        "set" => {
            arity(h, r, 2)?;
            Stmt::Set(sym(&r[0])?.to_string(), parse_expr(&r[1])?)
        }
        "field-store" => {
            arity(h, r, 3)?;
            return crate::lir::field_store(u32::try_from(int(&r[0])?).map_err(|_| "invalid field ID")?,
                parse_expr(&r[1])?, parse_expr(&r[2])?);
        }
        "vector-set" => {
            arity(h, r, 3)?;
            crate::lir::vector_set(parse_expr(&r[0])?, parse_expr(&r[1])?, parse_expr(&r[2])?)
        }
        "string-set" => {
            arity(h, r, 3)?;
            crate::lir::string_set(parse_expr(&r[0])?, parse_expr(&r[1])?, parse_expr(&r[2])?)
        }
        "instance-rack-set" => {
            arity(h, r, 2)?;
            return crate::lir::set_instance_rack(parse_expr(&r[0])?, parse_expr(&r[1])?);
        }
        "instance-slot-set" => {
            arity(h, r, 3)?;
            return crate::lir::set_instance_slot(parse_expr(&r[0])?, parse_expr(&r[1])?, parse_expr(&r[2])?);
        }
        "structure-slot-set" => {
            arity(h, r, 3)?;
            crate::lir::set_structure_slot(parse_expr(&r[0])?, parse_expr(&r[1])?, parse_expr(&r[2])?)
        }
        "funcallable-function-set" => {
            arity(h, r, 2)?;
            crate::lir::set_funcallable_function(parse_expr(&r[0])?, parse_expr(&r[1])?)
        }
        "tls-write" => {
            arity(h, r, 2)?;
            return crate::lir::tls_write(parse_expr(&r[0])?, parse_expr(&r[1])?);
        }
        "closure-set" => {
            arity(h, r, 3)?;
            return crate::lir::closure_set(parse_expr(&r[0])?, int(&r[1])?, parse_expr(&r[2])?);
        }
        "transfer-set" => {
            arity(h, r, 2)?;
            return crate::lir::transfer_set(int(&r[0])?, parse_expr(&r[1])?);
        }
        "transfer-set-dynamic" => {
            arity(h, r, 2)?;
            crate::lir::transfer_set_dynamic(parse_expr(&r[0])?, parse_expr(&r[1])?)
        }
        "transfer-roots" => {
            arity(h, r, 1)?;
            crate::lir::transfer_roots(parse_expr(&r[0])?)
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
        "switch" => {
            arity(h, r, 3)?;
            let mut entries = Vec::new();
            let mut seen = std::collections::HashSet::new();
            for entry in list(&r[2])? {
                let pair = list(entry)?;
                arity("switch entry", pair, 2)?;
                let key = int(&pair[0])?;
                if !seen.insert(key) {
                    return Err(format!("switch: duplicate key {key}"));
                }
                entries.push((key, sym(&pair[1])?.to_string()));
            }
            Stmt::Switch(parse_expr(&r[0])?, sym(&r[1])?.to_string(), entries)
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
        "tail-call-lisp" => {
            arity(h, r, 2)?;
            let args: Vec<Expr> = list(&r[1])?.iter().map(parse_expr).collect::<R<_>>()?;
            if args.len() < 3 || args.len() > 3 + REG_ARGS {
                return Err(format!("tail-call-lisp: bad argument count {}", args.len()));
            }
            Stmt::TailCallLisp {
                entry: parse_expr(&r[0])?,
                args,
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
        "fixnum-add-ovf" | "fixnum-sub-ovf" | "fixnum-mul-ovf" => {
            arity(h, r, 4)?;
            let op = match h {
                "fixnum-add-ovf" => OvfOp::Add,
                "fixnum-sub-ovf" => OvfOp::Sub,
                _ => OvfOp::Mul,
            };
            crate::lir::fixnum_arithmetic_ovf(op, sym(&r[0])?.to_string(),
                sym(&r[1])?.to_string(), parse_expr(&r[2])?, parse_expr(&r[3])?)
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
        "add" | "sub" | "mul" | "and" | "or" | "xor" | "sdiv" | "srem" | "shlv" | "sarv" | "f64-add" | "f64-sub" | "f64-mul" | "f64-div" | "f64-compare" => {
            arity(h, r, 2)?;
            let op = match h {
                "add" => BinOp::Add,
                "sub" => BinOp::Sub,
                "mul" => BinOp::Mul,
                "and" => BinOp::And,
                "or" => BinOp::Or,
                "sdiv" => BinOp::Sdiv,
                "srem" => BinOp::Srem,
                "f64-add" => BinOp::F64Add,
                "f64-sub" => BinOp::F64Sub,
                "f64-mul" => BinOp::F64Mul,
                "f64-div" => BinOp::F64Div,
                "f64-compare" => BinOp::F64Compare,
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
        "field-load" => {
            arity(h, r, 2)?;
            return crate::lir::field_load(u32::try_from(int(&r[0])?).map_err(|_| "invalid field ID")?, parse_expr(&r[1])?);
        }
        "unwind-target" => {
            arity(h, r, 0)?;
            crate::lir::unwind_target()
        }
        "unwind-packed" => {
            arity(h, r, 0)?;
            crate::lir::unwind_packed()
        }
        "fixnum-evenp" | "fixnum-half" => {
            arity(h, r, 1)?;
            return crate::lir::fixnum_operation(h, parse_expr(&r[0])?, None);
        }
        "fixnum-quotient" | "fixnum-remainder" | "fixnum-logand" | "fixnum-logior" |
        "fixnum-logxor" | "fixnum-lt" | "fixnum-gt" | "fixnum-ge" | "fixnum-eq" | "fixnum-le" | "fixnum-shift-left" | "fixnum-shift-right" => {
            arity(h, r, 2)?;
            return crate::lir::fixnum_operation(h, parse_expr(&r[0])?, Some(parse_expr(&r[1])?));
        }
        "fixnum-add" | "fixnum-sub" | "fixnum-mul" => {
            arity(h, r, 2)?;
            let op = match h {
                "fixnum-add" => OvfOp::Add,
                "fixnum-sub" => OvfOp::Sub,
                _ => OvfOp::Mul,
            };
            crate::lir::fixnum_arithmetic(op, parse_expr(&r[0])?, parse_expr(&r[1])?)
        }
        "fixnum-untag" => {
            arity(h, r, 1)?;
            crate::lir::fixnum_untag(parse_expr(&r[0])?)
        }
        "fixnum-unsigned-bits" => {
            arity(h, r, 1)?;
            crate::lir::fixnum_unsigned_bits(parse_expr(&r[0])?)
        }
        "unbound-value" => {
            arity(h, r, 0)?;
            Expr::Int(kiln_rt::object::UNBOUND as i64)
        }
        "unbound-slot-value" => {
            arity(h, r, 0)?;
            Expr::Int(kiln_rt::object::UNBOUND_SLOT as i64)
        }
        "poll-test" => {
            arity(h, r, 1)?;
            return crate::lir::poll_test(sym(&r[0])?);
        }
        "tls-address" => {
            arity(h, r, 1)?;
            crate::lir::tls_address(parse_expr(&r[0])?)
        }
        "tls-read" => {
            arity(h, r, 1)?;
            return crate::lir::tls_read(parse_expr(&r[0])?);
        }
        "no-tls-p" => {
            arity(h, r, 1)?;
            crate::lir::no_tls_value(parse_expr(&r[0])?)
        }
        "fixnum-tag" => {
            arity(h, r, 1)?;
            crate::lir::fixnum_tag(parse_expr(&r[0])?)
        }
        "vector-length" => {
            arity(h, r, 1)?;
            crate::lir::vector_length(parse_expr(&r[0])?)
        }
        "invalid-vector-length" => {
            arity(h, r, 1)?;
            crate::lir::invalid_vector_length(parse_expr(&r[0])?)
        }
        "invalid-rack-length" => {
            arity(h, r, 1)?;
            crate::lir::invalid_rack_length(parse_expr(&r[0])?)
        }
        "character-untag" => {
            arity(h, r, 1)?;
            crate::lir::character_untag(parse_expr(&r[0])?)
        }
        "character-tag" => {
            arity(h, r, 1)?;
            crate::lir::character_tag(parse_expr(&r[0])?)
        }
        "single-float-tag" => {
            arity(h, r, 1)?;
            crate::lir::single_float_tag(parse_expr(&r[0])?)
        }
        "single-float-bits" => {
            arity(h, r, 1)?;
            crate::lir::single_float_bits(parse_expr(&r[0])?)
        }
        "string-ref" => {
            arity(h, r, 2)?;
            crate::lir::string_ref(parse_expr(&r[0])?, parse_expr(&r[1])?)
        }
        "instance-rack" => {
            arity(h, r, 1)?;
            return crate::lir::instance_rack(parse_expr(&r[0])?);
        }
        "instance-class" => {
            arity(h, r, 1)?;
            return crate::lir::instance_class(parse_expr(&r[0])?);
        }
        "instance-slot" => {
            arity(h, r, 2)?;
            return crate::lir::instance_slot(parse_expr(&r[0])?, parse_expr(&r[1])?);
        }
        "structure-layout" => {
            arity(h, r, 1)?;
            crate::lir::structure_layout(parse_expr(&r[0])?)
        }
        "structure-slot" => {
            arity(h, r, 2)?;
            crate::lir::structure_slot(parse_expr(&r[0])?, parse_expr(&r[1])?)
        }
        "funcallable-function" => {
            arity(h, r, 1)?;
            crate::lir::funcallable_function(parse_expr(&r[0])?)
        }
        "vector-ref" => {
            arity(h, r, 2)?;
            crate::lir::vector_ref(parse_expr(&r[0])?, parse_expr(&r[1])?)
        }
        "stack-reference-base" => {
            arity(h, r, 3)?;
            return crate::lir::stack_reference_base(sym(&r[0])?.to_string(), u32::try_from(int(&r[1])?).map_err(|_| "invalid stack object class")?, int(&r[2])?);
        }
        "test-class" => {
            arity(h, r, 2)?;
            return crate::lir::test_class(u32::try_from(int(&r[0])?).map_err(|_| "invalid class ID")?, parse_expr(&r[1])?);
        }
        "test-header-class" => {
            arity(h, r, 2)?;
            return crate::lir::test_header_class(u32::try_from(int(&r[0])?).map_err(|_| "invalid class ID")?, parse_expr(&r[1])?);
        }
        "closure-ref" => {
            arity(h, r, 2)?;
            return crate::lir::closure_ref(parse_expr(&r[0])?, int(&r[1])?);
        }
        "transfer-ref" => {
            arity(h, r, 1)?;
            return crate::lir::transfer_ref(int(&r[0])?);
        }
        "transfer-ref-dynamic" => {
            arity(h, r, 1)?;
            crate::lir::transfer_ref_dynamic(parse_expr(&r[0])?)
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
            if r.len() != 1 && r.len() != 2 { return Err("addr: expected name and optional addend".into()); }
            let addend = if r.len() > 1 { int(&r[1])? } else { 0 };
            Expr::Addr(string(&r[0])?.to_string(), addend)
        }
        "object-address" => {
            arity(h, r, 2)?;
            Expr::Addr(string(&r[0])?.to_string(), crate::lir::static_object_tag(sym(&r[1])?)?)
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

#[cfg(test)]
mod tests {
    use super::*;

    fn stmt(text: &str) -> R<Stmt> {
        let form = crate::sexp::parse_one(text).map_err(|e| e.to_string())?;
        parse_stmt(&form)
    }

    #[test]
    fn immediate_data_words_validate_and_preserve_bits() {
        let word = |s: &str| parse_word(&crate::sexp::parse_one(s).unwrap());
        for (input, expected) in [
            ("(fixnum -4611686018427387904)", i64::MIN),
            ("(fixnum 4611686018427387903)", i64::MAX - 1),
            ("(character 0)", 0x0b_i64),
            ("(character 128512)", (128512_i64 << 8) | 0x0b),
            ("(single-float 0)", 0x1b),
            ("(single-float 2147483648)", i64::MIN | 0x1b),
            ("(single-float 4294967295)", 0xffff_ffff_0000_001b_u64 as i64),
        ] {
            assert!(matches!(word(input).unwrap(), Word::Int(n) if n == expected), "{input}");
        }
        for input in ["(fixnum -4611686018427387905)", "(fixnum 4611686018427387904)", "(character -1)", "(character 1114112)",
                      "(single-float -1)", "(single-float 4294967296)"] {
            assert!(word(input).is_err(), "{input}");
        }
    }

    #[test]
    fn switch_accepts_signed_keys_and_empty_table() {
        let Stmt::Switch(_, default, entries) =
            stmt("(switch v fallback ((-9223372036854775808 low) (9223372036854775807 high)))").unwrap()
        else {
            panic!("expected switch");
        };
        assert_eq!(default, "fallback");
        assert_eq!(entries, vec![(i64::MIN, "low".into()), (i64::MAX, "high".into())]);
        assert!(matches!(stmt("(switch v fallback ())").unwrap(), Stmt::Switch(_, _, v) if v.is_empty()));
    }

    #[test]
    fn switch_rejects_duplicate_keys_and_malformed_entries() {
        assert!(stmt("(switch v fallback ((1 a) (1 b)))").unwrap_err().contains("duplicate key"));
        assert!(stmt("(switch v fallback ((1)))").is_err());
        assert!(stmt("(switch v fallback ((a b)))").is_err());
        assert!(stmt("(switch v fallback ((1 2)))").is_err());
    }
}
