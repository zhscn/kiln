//! Value carriers and unwind payloads shared by the backend input adapters.
use super::*;
use crate::kir::{BinOp, Block, CmpOp, Loc, VarKind};

pub type Expansion = (Vec<(String, VarKind)>, Vec<Block>, String, Vec<Stmt>);

pub enum Packing {
    List,
    Compact,
    Reverse(Expr),
}

struct Builder {
    prefix: String,
    serial: usize,
    vars: Vec<(String, VarKind)>,
    blocks: Vec<Block>,
    block: String,
    statements: Vec<Stmt>,
    handler: Option<String>,
}
fn var(name: impl Into<String>) -> Expr {
    Expr::Var(name.into())
}
fn nil() -> Expr {
    Expr::Addr("kiln_nil".into(), TAG_GENERAL as i64)
}
fn cmp(op: CmpOp, a: Expr, b: Expr) -> Expr {
    Expr::Cmp(op, Box::new(a), Box::new(b))
}
impl Builder {
    fn new(prefix: &str, block: String, statements: Vec<Stmt>, handler: Option<String>) -> Self {
        Self {
            prefix: prefix.into(),
            serial: 0,
            vars: vec![],
            blocks: vec![],
            block,
            statements,
            handler,
        }
    }
    fn fresh(&mut self) -> String {
        let name = format!("{}_t{}", self.prefix, self.serial);
        self.serial += 1;
        name
    }
    fn temporary(&mut self, kind: VarKind) -> String {
        let name = self.fresh();
        self.vars.push((name.clone(), kind));
        name
    }
    fn emit(&mut self, statement: Stmt) {
        self.statements.push(statement);
    }
    fn finish(&mut self, next: String) {
        self.blocks.push(Block {
            name: std::mem::replace(&mut self.block, next),
            stmts: std::mem::take(&mut self.statements),
        });
    }
    fn take(self) -> Expansion {
        (self.vars, self.blocks, self.block, self.statements)
    }
    fn append(&mut self, expansion: Expansion) {
        let (vars, blocks, next, statements) = expansion;
        self.vars.extend(vars);
        self.blocks.extend(blocks);
        self.block = next;
        self.statements = statements;
    }
    fn cons(&mut self, result: String, car: Expr, cdr: Expr) -> Result<(), String> {
        let head = self.temporary(VarKind::Obj);
        let tail = self.temporary(VarKind::Obj);
        self.emit(Stmt::Set(head.clone(), car));
        self.emit(Stmt::Set(tail.clone(), cdr));
        let raw = self.temporary(VarKind::Raw);
        let prefix = self.fresh();
        let (bytes, header, _, _) = fixed_layout(CLASS_CONS)?;
        let expansion = allocate_raw(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            raw.clone(),
            Expr::Int(bytes),
            Expr::Int(header),
            true,
            "kiln_rt_alloc".into(),
            self.handler.clone(),
        )?;
        self.append(expansion);
        self.statements.extend(initialize_fixed(
            result,
            raw,
            CLASS_CONS,
            vec![var(head), var(tail)],
        )?);
        Ok(())
    }
    fn error(&mut self, code: u64, value: Expr, loc: Option<Loc>) -> Result<(), String> {
        let prefix = self.fresh();
        let expansion = runtime_error(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            code as i64,
            value,
            self.handler.clone(),
            loc,
        )?;
        self.append(expansion);
        Ok(())
    }
    fn require(&mut self, test: Expr, code: u64, value: Expr) -> Result<(), String> {
        let good = self.fresh();
        let bad = self.fresh();
        self.emit(Stmt::Br(test, good.clone(), bad.clone()));
        self.finish(bad);
        self.error(code, value, None)?;
        self.finish(good);
        Ok(())
    }
    fn pack_list(
        &mut self,
        result: String,
        primary: Expr,
        count: Expr,
        reverse: Option<Expr>,
    ) -> Result<(), String> {
        let first = self.temporary(VarKind::Obj);
        let number = self.temporary(VarKind::Raw);
        let index = self.temporary(VarKind::Raw);
        let item = self.temporary(VarKind::Obj);
        self.emit(Stmt::Set(first.clone(), primary));
        self.emit(Stmt::Set(number.clone(), count));
        let forward = reverse.is_some();
        self.emit(Stmt::Set(result.clone(), reverse.unwrap_or_else(nil)));
        self.emit(counted_transfer_roots(var(&number), false)?);
        self.emit(Stmt::Set(
            index.clone(),
            if forward { Expr::Int(0) } else { var(&number) },
        ));
        let head = self.fresh();
        let body = self.fresh();
        let one = self.fresh();
        let many = self.fresh();
        let cons = self.fresh();
        let done = self.fresh();
        self.emit(Stmt::Jump(head.clone()));
        self.finish(head.clone());
        let test = if forward {
            cmp(CmpOp::Lt, var(&index), var(&number))
        } else {
            cmp(CmpOp::Gt, var(&index), Expr::Int(0))
        };
        self.emit(Stmt::Br(test, body.clone(), done.clone()));
        self.finish(body);
        if !forward {
            self.emit(Stmt::Set(
                index.clone(),
                Expr::Bin(BinOp::Sub, Box::new(var(&index)), Box::new(Expr::Int(1))),
            ));
        }
        self.emit(Stmt::Br(
            cmp(CmpOp::Eq, var(&index), Expr::Int(0)),
            one.clone(),
            many.clone(),
        ));
        self.finish(one);
        self.emit(Stmt::Set(item.clone(), var(first)));
        self.emit(Stmt::Jump(cons.clone()));
        self.finish(many);
        self.emit(Stmt::Set(item.clone(), secondary_value_ref(var(&index))?));
        self.emit(Stmt::Jump(cons.clone()));
        self.finish(cons);
        self.cons(result.clone(), var(item), var(&result))?;
        if forward {
            self.emit(Stmt::Set(
                index.clone(),
                Expr::Bin(BinOp::Add, Box::new(var(&index)), Box::new(Expr::Int(1))),
            ));
        }
        self.emit(Stmt::Jump(head));
        self.finish(done);
        self.emit(transfer_roots(Expr::Int(0)));
        Ok(())
    }
    fn pack(
        &mut self,
        result: String,
        primary: Expr,
        count: Expr,
        mode: Packing,
    ) -> Result<(), String> {
        match mode {
            Packing::List => self.pack_list(result, primary, count, None),
            Packing::Reverse(acc) => self.pack_list(result, primary, count, Some(acc)),
            Packing::Compact => {
                let first = self.temporary(VarKind::Obj);
                let number = self.temporary(VarKind::Raw);
                self.emit(Stmt::Set(first.clone(), primary));
                self.emit(Stmt::Set(number.clone(), count));
                let one = self.fresh();
                let many = self.fresh();
                let done = self.fresh();
                self.emit(Stmt::Br(
                    cmp(CmpOp::Eq, var(&number), Expr::Int(1)),
                    one.clone(),
                    many.clone(),
                ));
                self.finish(one);
                self.emit(Stmt::Set(result.clone(), var(&first)));
                self.emit(Stmt::Jump(done.clone()));
                self.finish(many);
                self.pack_list(result, var(first), var(number), None)?;
                self.emit(Stmt::Jump(done.clone()));
                self.finish(done);
                Ok(())
            }
        }
    }
    fn restore_list(
        &mut self,
        primary: String,
        count: String,
        cursor: String,
        checked: bool,
    ) -> Result<(), String> {
        self.emit(Stmt::Set(primary.clone(), nil()));
        self.emit(Stmt::Set(count.clone(), Expr::Int(0)));
        let first = self.fresh();
        let head = self.fresh();
        let body = self.fresh();
        let done = self.fresh();
        self.emit(Stmt::Br(
            cmp(CmpOp::Eq, var(&cursor), nil()),
            done.clone(),
            first.clone(),
        ));
        self.finish(first);
        if checked {
            self.require(
                test_class(CLASS_CONS, var(&cursor))?,
                kiln_rt::rtfun::ERR_NOT_LIST,
                var(&cursor),
            )?;
        }
        self.emit(Stmt::Set(
            primary,
            field_load(FIELD_CONS_CAR, var(&cursor))?,
        ));
        self.emit(Stmt::Set(
            cursor.clone(),
            field_load(FIELD_CONS_CDR, var(&cursor))?,
        ));
        self.emit(Stmt::Set(count.clone(), Expr::Int(1)));
        self.emit(Stmt::Jump(head.clone()));
        self.finish(head.clone());
        self.emit(Stmt::Br(
            cmp(CmpOp::Eq, var(&cursor), nil()),
            done.clone(),
            body.clone(),
        ));
        self.finish(body);
        if checked {
            self.require(
                test_class(CLASS_CONS, var(&cursor))?,
                kiln_rt::rtfun::ERR_NOT_LIST,
                var(&cursor),
            )?;
            self.require(
                cmp(
                    CmpOp::Le,
                    var(&count),
                    Expr::Int(kiln_rt::context::VALUES_MAX as i64),
                ),
                kiln_rt::rtfun::ERR_WRONG_NARGS,
                fixnum_tag(var(&count)),
            )?;
        }
        self.emit(secondary_value_set(
            var(&count),
            field_load(FIELD_CONS_CAR, var(&cursor))?,
        )?);
        self.emit(Stmt::Set(
            cursor.clone(),
            field_load(FIELD_CONS_CDR, var(&cursor))?,
        ));
        self.emit(Stmt::Set(
            count.clone(),
            Expr::Bin(BinOp::Add, Box::new(var(&count)), Box::new(Expr::Int(1))),
        ));
        self.emit(Stmt::Jump(head));
        self.finish(done);
        self.emit(transfer_roots(Expr::Int(0)));
        Ok(())
    }
    fn restore(
        &mut self,
        primary: String,
        count: String,
        saved: Expr,
        compact: Option<Expr>,
        checked: bool,
    ) -> Result<(), String> {
        let cursor = self.temporary(VarKind::Obj);
        self.emit(Stmt::Set(cursor.clone(), saved));
        if let Some(number) = compact {
            let n = self.temporary(VarKind::Raw);
            self.emit(Stmt::Set(n.clone(), number));
            let one = self.fresh();
            let many = self.fresh();
            let done = self.fresh();
            self.emit(Stmt::Br(
                cmp(CmpOp::Eq, var(n), Expr::Int(1)),
                one.clone(),
                many.clone(),
            ));
            self.finish(one);
            self.emit(Stmt::Set(primary.clone(), var(&cursor)));
            self.emit(Stmt::Set(count.clone(), Expr::Int(1)));
            self.emit(Stmt::Jump(done.clone()));
            self.finish(many);
            self.restore_list(primary, count, cursor, checked)?;
            self.emit(Stmt::Jump(done.clone()));
            self.finish(done);
            Ok(())
        } else {
            self.restore_list(primary, count, cursor, checked)
        }
    }
}
#[allow(clippy::too_many_arguments)]
pub fn pack(
    prefix: &str,
    start: String,
    before: Vec<Stmt>,
    result: String,
    primary: Expr,
    count: Expr,
    mode: Packing,
    handler: Option<String>,
) -> Result<Expansion, String> {
    let mut b = Builder::new(prefix, start, before, handler);
    b.pack(result, primary, count, mode)?;
    Ok(b.take())
}
#[allow(clippy::too_many_arguments)]
pub fn restore(
    prefix: &str,
    start: String,
    before: Vec<Stmt>,
    primary: String,
    count: String,
    saved: Expr,
    compact: Option<Expr>,
    checked: bool,
    handler: Option<String>,
) -> Result<Expansion, String> {
    let mut b = Builder::new(prefix, start, before, handler);
    b.restore(primary, count, saved, compact, checked)?;
    Ok(b.take())
}
#[allow(clippy::too_many_arguments)]
pub fn unwind(
    prefix: &str,
    start: String,
    before: Vec<Stmt>,
    target: Expr,
    primary: Expr,
    count: Expr,
    exit: bool,
    handler: Option<String>,
    loc: Option<Loc>,
) -> Result<Expansion, String> {
    let mut b = Builder::new(prefix, start, before, handler.clone());
    let tag = b.temporary(VarKind::Obj);
    let payload = b.temporary(VarKind::Obj);
    let flag = b.temporary(VarKind::Raw);
    b.emit(Stmt::Set(tag.clone(), target));
    let one = b.fresh();
    let many = b.fresh();
    let done = b.fresh();
    b.emit(Stmt::Br(
        cmp(CmpOp::Eq, count.clone(), Expr::Int(1)),
        one.clone(),
        many.clone(),
    ));
    b.finish(one);
    b.emit(Stmt::Set(payload.clone(), primary.clone()));
    b.emit(Stmt::Set(flag.clone(), Expr::Int(0)));
    b.emit(Stmt::Jump(done.clone()));
    b.finish(many);
    b.pack(payload.clone(), primary, count, Packing::List)?;
    b.emit(Stmt::Set(flag.clone(), Expr::Int(1)));
    b.emit(Stmt::Jump(done.clone()));
    b.finish(done);
    b.emit(Stmt::CallRt {
        name: if exit {
            "kiln_rt_exit_to"
        } else {
            "kiln_rt_throw"
        }
        .into(),
        results: vec![],
        args: vec![var("ctx"), var(&tag), var(payload), var(flag)],
        handler,
        loc,
    });
    b.error(
        if exit {
            kiln_rt::rtfun::ERR_EXPIRED_EXIT
        } else {
            kiln_rt::rtfun::ERR_NO_CATCH_TAG
        },
        var(tag),
        loc,
    )?;
    Ok(b.take())
}

pub fn land(
    prefix: &str,
    start: String,
    before: Vec<Stmt>,
    primary: String,
    count: String,
) -> Result<Expansion, String> {
    let mut b = Builder::new(prefix, start, before, None);
    let one = b.fresh();
    let packed = b.fresh();
    let done = b.fresh();
    b.emit(Stmt::Br(unwind_packed(), packed.clone(), one.clone()));
    b.finish(one);
    b.emit(Stmt::Set(primary.clone(), var("exn1")));
    b.emit(Stmt::Set(count.clone(), Expr::Int(1)));
    b.emit(Stmt::Jump(done.clone()));
    b.finish(packed);
    b.restore(primary, count, var("exn1"), None, false)?;
    b.emit(Stmt::Jump(done.clone()));
    b.finish(done);
    Ok(b.take())
}
pub fn continue_unwind(entry: String, handler: Option<String>, loc: Option<Loc>) -> Vec<Stmt> {
    vec![
        Stmt::CallRt {
            name: "kiln_rt_continue_unwind".into(),
            results: vec![],
            args: vec![var("ctx"), Expr::Slot(entry)],
            handler,
            loc,
        },
        Stmt::Trap,
    ]
}
pub fn register_imports(module: &mut crate::kir::Module) -> Result<(), String> {
    use crate::kir::ImportFunc;
    for (name, params, noreturn) in [
        ("kiln_rt_throw", 4, false),
        ("kiln_rt_exit_to", 4, false),
        ("kiln_rt_continue_unwind", 2, true),
    ] {
        if !module
            .funcs
            .iter()
            .flat_map(|f| &f.blocks)
            .flat_map(|b| &b.stmts)
            .any(|s| matches!(s,Stmt::CallRt {name:n,..} if n==name))
        {
            continue;
        }
        if let Some(f) = module.import_funcs.iter().find(|f| f.name == name) {
            if f.params != params || f.returns != 0 || !f.unwinds || f.noreturn != noreturn {
                return Err(format!("unwind operation requires the signature of {name}"));
            }
        } else {
            module.import_funcs.push(ImportFunc {
                name: name.into(),
                params,
                returns: 0,
                unwinds: true,
                noreturn,
            });
        }
    }
    Ok(())
}
