//! Save complete binding state before linking a PROGV entry or changing TLS.
use super::expansion::{Builder, Expansion};
use super::*;
use crate::kir::{CmpOp, VarKind};
use crate::lir as layout;
fn var(name: impl Into<String>) -> Expr {
    Expr::Var(name.into())
}
fn nil() -> Expr {
    Expr::Addr("kiln_nil".into(), TAG_GENERAL as i64)
}
fn compare(op: CmpOp, a: Expr, b: Expr) -> Expr {
    Expr::Cmp(op, Box::new(a), Box::new(b))
}
impl Builder {
    fn tls_index(&mut self, symbol: String) -> Result<(), String> {
        let result = self.temporary(VarKind::Raw);
        let prefix = self.fresh();
        let (blocks, next) = layout::ensure_tls_index(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            result,
            symbol,
        )?;
        self.blocks.extend(blocks);
        self.block = next;
        Ok(())
    }
    fn enter_progv(&mut self, entry: String, symbols: Expr, values: Expr) -> Result<(), String> {
        let syms = self.temporary(VarKind::Obj);
        let vals = self.temporary(VarKind::Obj);
        let cursor = self.temporary(VarKind::Obj);
        let saved = self.temporary(VarKind::Obj);
        let symbol = self.temporary(VarKind::Obj);
        let pair = self.temporary(VarKind::Obj);
        let value = self.temporary(VarKind::Obj);
        let nil = nil();
        self.emit(Stmt::Set(syms.clone(), symbols));
        self.emit(Stmt::Set(vals.clone(), values));
        self.emit(Stmt::Set(cursor.clone(), var(&syms)));
        self.emit(Stmt::Set(saved.clone(), nil.clone()));
        let head = self.fresh();
        let body = self.fresh();
        let bind = self.fresh();
        self.emit(Stmt::Jump(head.clone()));
        self.finish(head.clone());
        self.emit(Stmt::Br(
            compare(CmpOp::Eq, var(&cursor), nil.clone()),
            bind.clone(),
            body.clone(),
        ));
        self.finish(body);
        self.emit(Stmt::Set(
            symbol.clone(),
            layout::field_load(FIELD_CONS_CAR, var(&cursor))?,
        ));
        self.tls_index(symbol.clone())?;
        self.emit(Stmt::Set(value.clone(), layout::tls_read(var(&symbol))?));
        self.cons(pair.clone(), var(&symbol), var(&value))?;
        self.cons(saved.clone(), var(&pair), var(&saved))?;
        self.emit(Stmt::Set(
            cursor.clone(),
            layout::field_load(FIELD_CONS_CDR, var(&cursor))?,
        ));
        self.emit(Stmt::Jump(head));
        self.finish(bind);
        // No binding changes until the complete restoration list is rooted by
        // the entry. The remaining stores cannot allocate or unwind.
        self.statements.extend(layout::enter_dynamic_entry(
            entry.clone(),
            "progv",
            var(&saved),
        )?);
        self.emit(Stmt::Set(cursor.clone(), var(syms)));
        let head = self.fresh();
        let body = self.fresh();
        let absent = self.fresh();
        let present = self.fresh();
        let store = self.fresh();
        let done = self.fresh();
        self.emit(Stmt::Jump(head.clone()));
        self.finish(head.clone());
        self.emit(Stmt::Br(
            compare(CmpOp::Eq, var(&cursor), nil.clone()),
            done.clone(),
            body.clone(),
        ));
        self.finish(body);
        self.emit(Stmt::Br(
            compare(CmpOp::Eq, var(&vals), nil),
            absent.clone(),
            present.clone(),
        ));
        self.finish(absent);
        self.emit(Stmt::Set(
            value.clone(),
            Expr::Int(kiln_rt::object::UNBOUND as i64),
        ));
        self.emit(Stmt::Jump(store.clone()));
        self.finish(present);
        self.emit(Stmt::Set(
            value.clone(),
            layout::field_load(FIELD_CONS_CAR, var(&vals))?,
        ));
        self.emit(Stmt::Set(
            vals.clone(),
            layout::field_load(FIELD_CONS_CDR, var(&vals))?,
        ));
        self.emit(Stmt::Jump(store.clone()));
        self.finish(store);
        self.emit(layout::tls_write(
            layout::field_load(FIELD_CONS_CAR, var(&cursor))?,
            var(value),
        )?);
        self.emit(Stmt::Set(
            cursor.clone(),
            layout::field_load(FIELD_CONS_CDR, var(&cursor))?,
        ));
        self.emit(Stmt::Jump(head));
        self.finish(done);
        Ok(())
    }

    fn leave_progv(&mut self, entry: String) -> Result<(), String> {
        let cursor = self.temporary(VarKind::Obj);
        let pair = self.temporary(VarKind::Obj);
        self.emit(layout::progv_bindings(cursor.clone(), entry.clone()));
        let head = self.fresh();
        let body = self.fresh();
        let done = self.fresh();
        let nil = nil();
        self.emit(Stmt::Jump(head.clone()));
        self.finish(head.clone());
        self.emit(Stmt::Br(
            compare(CmpOp::Eq, var(&cursor), nil),
            done.clone(),
            body.clone(),
        ));
        self.finish(body);
        self.emit(Stmt::Set(
            pair.clone(),
            layout::field_load(FIELD_CONS_CAR, var(&cursor))?,
        ));
        self.emit(layout::tls_write(
            layout::field_load(FIELD_CONS_CAR, var(&pair))?,
            layout::field_load(FIELD_CONS_CDR, var(&pair))?,
        )?);
        self.emit(Stmt::Set(
            cursor.clone(),
            layout::field_load(FIELD_CONS_CDR, var(&cursor))?,
        ));
        self.emit(Stmt::Jump(head));
        self.finish(done);
        Ok(())
    }
}
#[allow(clippy::too_many_arguments)]
pub fn enter(
    prefix: &str,
    block: String,
    statements: Vec<Stmt>,
    entry: String,
    symbols: Expr,
    values: Expr,
    handler: Option<String>,
) -> Result<Expansion, String> {
    let mut b = Builder::new(prefix, block, statements, handler);
    b.enter_progv(entry, symbols, values)?;
    Ok(b.take())
}
pub fn restore(
    prefix: &str,
    block: String,
    statements: Vec<Stmt>,
    entry: String,
) -> Result<Expansion, String> {
    let mut b = Builder::new(prefix, block, statements, None);
    b.leave_progv(entry)?;
    Ok(b.take())
}
