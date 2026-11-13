//! Shared state for expansions that introduce variables and control flow.
use super::*;
use crate::kir::{Block, Loc, VarKind};

pub type Expansion = (Vec<(String, VarKind)>, Vec<Block>, String, Vec<Stmt>);

pub(super) struct Builder {
    pub(super) prefix: String,
    pub(super) serial: usize,
    pub(super) vars: Vec<(String, VarKind)>,
    pub(super) blocks: Vec<Block>,
    pub(super) block: String,
    pub(super) statements: Vec<Stmt>,
    pub(super) handler: Option<String>,
}
fn var(name: impl Into<String>) -> Expr {
    Expr::Var(name.into())
}
impl Builder {
    pub(super) fn new(
        prefix: &str,
        block: String,
        statements: Vec<Stmt>,
        handler: Option<String>,
    ) -> Self {
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
    pub(super) fn fresh(&mut self) -> String {
        let name = format!("{}_t{}", self.prefix, self.serial);
        self.serial += 1;
        name
    }
    pub(super) fn temporary(&mut self, kind: VarKind) -> String {
        let name = self.fresh();
        self.vars.push((name.clone(), kind));
        name
    }
    pub(super) fn emit(&mut self, statement: Stmt) {
        self.statements.push(statement);
    }
    pub(super) fn finish(&mut self, next: String) {
        self.blocks.push(Block {
            name: std::mem::replace(&mut self.block, next),
            stmts: std::mem::take(&mut self.statements),
        });
    }
    pub(super) fn take(self) -> Expansion {
        (self.vars, self.blocks, self.block, self.statements)
    }
    pub(super) fn append(&mut self, expansion: Expansion) {
        let (vars, blocks, next, statements) = expansion;
        self.vars.extend(vars);
        self.blocks.extend(blocks);
        self.block = next;
        self.statements = statements;
    }
    pub(super) fn cons(&mut self, result: String, car: Expr, cdr: Expr) -> Result<(), String> {
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
    pub(super) fn error(&mut self, code: u64, value: Expr, loc: Option<Loc>) -> Result<(), String> {
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
    pub(super) fn require(&mut self, test: Expr, code: u64, value: Expr) -> Result<(), String> {
        let good = self.fresh();
        let bad = self.fresh();
        self.emit(Stmt::Br(test, good.clone(), bad.clone()));
        self.finish(bad);
        self.error(code, value, None)?;
        self.finish(good);
        Ok(())
    }
}
