use super::*;
use crate::kir::{BinOp, CmpOp, Data, DataContents, Expr, ImportFunc, Stmt, VarKind, Word};
use crate::lir as layout;
use std::collections::{HashMap, HashSet};

fn object_label(name: &str) -> String {
    format!("_kiln_lir_object_{name}")
}
fn var(name: impl Into<String>) -> Expr {
    Expr::Var(name.into())
}
fn object(name: impl Into<String>) -> Expr {
    Expr::Addr(name.into(), kiln_rt::object::TAG_GENERAL as i64)
}
fn compare(op: CmpOp, a: Expr, b: Expr) -> Expr {
    Expr::Cmp(op, Box::new(a), Box::new(b))
}

struct Lowerer<'a> {
    function: kir::Func,
    constants: &'a [Expr],
    cells: String,
    rest_roots: Vec<String>,
    names: HashMap<&'a str, String>,
    blocks: HashMap<&'a str, String>,
    imports: &'a mut HashSet<String>,
    regions: &'a [Region],
    functions: &'a [Function],
    slots: Vec<String>,
    stack_slots: HashMap<&'a str, String>,
    stack_objects: &'a [StackObject],
    active: Vec<ActiveRegion>,
    handlers: Vec<(Vec<usize>, String)>,
    block: String,
    statements: Vec<Stmt>,
    next: usize,
}

impl Lowerer<'_> {
    fn fresh(&mut self) -> String {
        let name = format!("t{}", self.next);
        self.next += 1;
        name
    }
    fn temporary(&mut self, ty: VarKind) -> String {
        let name = self.fresh();
        self.function.vars.push((name.clone(), ty));
        name
    }
    fn emit(&mut self, statement: Stmt) {
        self.statements.push(statement);
    }
    fn finish(&mut self, next: String) {
        self.function.blocks.push(kir::Block {
            name: std::mem::replace(&mut self.block, next),
            stmts: std::mem::take(&mut self.statements),
        });
    }
    fn name(&self, name: &str) -> String {
        self.names[name].clone()
    }
    fn value(&self, name: &str) -> Expr {
        var(self.name(name))
    }
    fn values(&self, names: &[String]) -> Vec<Expr> {
        names.iter().map(|name| self.value(name)).collect()
    }
    fn view(&self, name: &str) -> (String, String) {
        let name = self.name(name);
        (format!("{name}_primary"), format!("{name}_count"))
    }
    fn nil(&mut self) -> Expr {
        self.imports.insert("kiln_nil".into());
        object("kiln_nil")
    }
    fn region(&self, name: &str) -> usize {
        self.regions.iter().position(|r| r.name == name).unwrap()
    }
    fn handler(&mut self) -> Option<String> {
        let chain: Vec<_> = self
            .active
            .iter()
            .filter(|r| !r.cleanup && self.regions[r.region].kind.has_handler())
            .map(|r| r.region)
            .collect();
        let mut result = None;
        for len in 1..=chain.len() {
            let key = &chain[..len];
            let name = if let Some((_, name)) = self.handlers.iter().find(|(old, _)| old == key) {
                name.clone()
            } else {
                let name = self.fresh();
                self.handlers.push((key.to_vec(), name.clone()));
                name
            };
            result = Some(name);
        }
        result
    }
    fn dispatchers(&mut self) -> Result<()> {
        if self.handlers.is_empty() {
            return Ok(());
        }
        let unhandled = self.fresh();
        for (chain, label) in self.handlers.clone() {
            self.block = label;
            self.emit(layout::transfer_roots(Expr::Int(0)));
            let region = *chain.last().unwrap();
            let outer = self
                .handlers
                .iter()
                .find(|(key, _)| key == &chain[..chain.len() - 1])
                .map(|(_, label)| label.clone())
                .unwrap_or_else(|| unhandled.clone());
            self.emit(Stmt::Br(
                compare(
                    CmpOp::Eq,
                    layout::unwind_target(),
                    Expr::Slot(self.slots[region].clone()),
                ),
                self.blocks[self.regions[region].landing.as_ref().unwrap().as_str()].clone(),
                outer,
            ));
            self.finish(String::new());
        }
        self.block = unhandled;
        self.emit(Stmt::Trap);
        self.finish(String::new());
        Ok(())
    }

    fn allocate(&mut self, result: String, kind: Allocation, fields: Vec<Expr>) -> Result<()> {
        // Preserve old fields when RESULT aliases an input, and keep every
        // object field rooted across the allocator's slow path.
        let mut values = Vec::new();
        for (field, ty) in fields.into_iter().zip(kind.fields()) {
            let temp = self.temporary(if *ty == Type::F64 {
                VarKind::F64
            } else {
                VarKind::Obj
            });
            self.emit(Stmt::Set(temp.clone(), field));
            values.push(var(temp));
        }
        let raw = self.temporary(VarKind::Raw);
        let prefix = self.fresh();
        let class = kind.class().id();
        let (bytes, header, _, _) = layout::fixed_layout(class)?;
        let handler = self.handler();
        let (vars, blocks, next, statements) = layout::allocate_raw(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            raw.clone(),
            Expr::Int(bytes),
            Expr::Int(header),
            true,
            "kiln_rt_alloc".into(),
            handler,
        )?;
        self.function.vars.extend(vars);
        self.function.blocks.extend(blocks);
        self.block = next;
        self.statements = statements;
        self.statements
            .extend(layout::initialize_fixed(result, raw, class, values)?);
        Ok(())
    }

    fn require(&mut self, condition: Expr, code: i64, value: Expr) -> Result<()> {
        let good = self.fresh();
        let bad = self.fresh();
        self.emit(Stmt::Br(condition, good.clone(), bad.clone()));
        self.finish(bad);
        self.error(code, value)?;
        self.finish(good);
        Ok(())
    }
    fn allocate_sequence(
        &mut self,
        result: String,
        kind: SequenceKind,
        length: Expr,
        initial: Expr,
    ) -> Result<()> {
        let n = self.temporary(VarKind::Raw);
        let value = self.temporary(VarKind::Obj);
        self.emit(Stmt::Set(n.clone(), length));
        self.emit(Stmt::Set(value.clone(), initial));
        self.require(
            Expr::Bin(
                BinOp::And,
                Box::new(compare(CmpOp::Ge, var(&n), Expr::Int(0))),
                Box::new(compare(CmpOp::Le, var(&n), Expr::Int(u32::MAX as i64))),
            ),
            kiln_rt::rtfun::ERR_INDEX as i64,
            layout::fixnum_tag(var(&n)),
        )?;
        let initial = match kind {
            SequenceKind::Vector => var(&value),
            SequenceKind::String => {
                self.require(
                    layout::test_class(crate::packet::schema::CLASS_CHARACTER, var(&value))?,
                    kiln_rt::rtfun::ERR_NOT_CHARACTER as i64,
                    var(&value),
                )?;
                layout::character_untag(var(&value))
            }
        };
        let raw = self.temporary(VarKind::Raw);
        let prefix = self.fresh();
        let (bytes, header, shift) = layout::vector_layout(kind.class(), &var(&n))?;
        let handler = self.handler();
        let (vars, blocks, next, statements) = layout::allocate_raw(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            raw.clone(),
            bytes,
            header,
            shift == 2,
            "kiln_rt_alloc".into(),
            handler,
        )?;
        self.function.vars.extend(vars);
        self.function.blocks.extend(blocks);
        let (vars, blocks, next, statements) = layout::initialize_vector(
            &prefix,
            next,
            statements,
            result,
            raw,
            var(&n),
            initial,
            shift,
        );
        self.function.vars.extend(vars);
        self.function.blocks.extend(blocks);
        self.block = next;
        self.statements = statements;
        Ok(())
    }
    fn vector(&mut self, result: String, elements: Vec<Expr>) -> Result<()> {
        let mut values = Vec::new();
        for element in elements {
            let temp = self.temporary(VarKind::Obj);
            self.emit(Stmt::Set(temp.clone(), element));
            values.push(var(temp));
        }
        let (bytes, header, _) = layout::vector_layout(
            crate::packet::schema::CLASS_SIMPLE_VECTOR,
            &Expr::Int(values.len() as i64),
        )?;
        let raw = self.temporary(VarKind::Raw);
        let prefix = self.fresh();
        let handler = self.handler();
        let (vars, blocks, next, mut statements) = layout::allocate_raw(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            raw.clone(),
            bytes,
            header,
            false,
            "kiln_rt_alloc".into(),
            handler,
        )?;
        statements.extend(layout::initialize_vector_elements(result, raw, values));
        self.function.vars.extend(vars);
        self.function.blocks.extend(blocks);
        self.block = next;
        self.statements = statements;
        Ok(())
    }

    fn allocate_indexed_object(
        &mut self,
        result: String,
        descriptor: Expr,
        count: Expr,
        initial: Expr,
        instance: Option<(bool, Expr, Expr)>,
    ) -> Result<()> {
        let count_name = self.temporary(VarKind::Raw);
        self.emit(Stmt::Set(count_name.clone(), count));
        let save = |this: &mut Self, value: Expr| {
            let temp = this.temporary(VarKind::Obj);
            this.emit(Stmt::Set(temp.clone(), value));
            var(temp)
        };
        let descriptor = save(self, descriptor);
        let initial = save(self, initial);
        let instance = instance
            .map(|(callable, stamp, slots)| (callable, save(self, stamp), save(self, slots)));
        let limit = if instance.is_some() {
            u32::MAX - 3
        } else {
            u32::MAX
        };
        self.require(
            Expr::Bin(
                BinOp::And,
                Box::new(compare(CmpOp::Ge, var(&count_name), Expr::Int(0))),
                Box::new(compare(
                    CmpOp::Le,
                    var(&count_name),
                    Expr::Int(i64::from(limit)),
                )),
            ),
            kiln_rt::rtfun::ERR_INDEX as i64,
            layout::fixnum_tag(var(&count_name)),
        )?;
        let rack_count = Expr::Bin(
            BinOp::Add,
            Box::new(var(&count_name)),
            Box::new(Expr::Int(2)),
        );
        let (bytes, header) = if instance.is_some() {
            layout::rack_allocation_layout(&rack_count)?
        } else {
            layout::structure_allocation_layout(&var(&count_name))?
        };
        let raw = self.temporary(VarKind::Raw);
        let prefix = self.fresh();
        let handler = self.handler();
        let (vars, blocks, next, statements) = layout::allocate_raw(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            raw.clone(),
            bytes,
            header,
            true,
            "kiln_rt_alloc".into(),
            handler,
        )?;
        self.function.vars.extend(vars);
        self.function.blocks.extend(blocks);
        let object = self.temporary(VarKind::Obj);
        let length = Expr::Bin(
            BinOp::Add,
            Box::new(var(&count_name)),
            Box::new(Expr::Int(if instance.is_some() { 3 } else { 1 })),
        );
        let (vars, blocks, next, statements) = layout::initialize_vector(
            &prefix,
            next,
            statements,
            object.clone(),
            raw.clone(),
            length,
            initial,
            3,
        );
        self.function.vars.extend(vars);
        self.function.blocks.extend(blocks);
        self.block = next;
        self.statements = statements;
        self.emit(Stmt::Store(var(&raw), 8, descriptor));
        if let Some((funcallable, stamp, slots)) = instance {
            self.emit(Stmt::Store(var(&raw), 16, stamp));
            self.emit(Stmt::Store(var(&raw), 24, slots));
            if funcallable {
                self.allocate_funcallable(result, var(object))?;
            } else {
                self.allocate(result, Allocation::Instance, vec![var(object)])?;
            }
        } else {
            self.emit(Stmt::Set(result, var(object)));
        }
        Ok(())
    }
    fn allocate_funcallable(&mut self, result: String, rack: Expr) -> Result<()> {
        self.imports.insert("kiln_funcallable_trampoline".into());
        self.imports.insert("kiln_funcallable_unset_fobj".into());
        let rack_name = self.temporary(VarKind::Obj);
        self.emit(Stmt::Set(rack_name.clone(), rack));
        let raw = self.temporary(VarKind::Raw);
        let prefix = self.fresh();
        let handler = self.handler();
        let (bytes, header, _, _) =
            layout::fixed_layout(crate::packet::schema::CLASS_FUNCALLABLE_INSTANCE)?;
        let (vars, blocks, next, mut statements) = layout::allocate_raw(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            raw.clone(),
            Expr::Int(bytes),
            Expr::Int(header),
            true,
            "kiln_rt_alloc".into(),
            handler,
        )?;
        statements.extend(layout::initialize_fixed(
            result,
            raw,
            crate::packet::schema::CLASS_FUNCALLABLE_INSTANCE,
            vec![
                Expr::Addr("kiln_funcallable_trampoline".into(), 0),
                var(rack_name),
                object("kiln_funcallable_unset_fobj"),
            ],
        )?);
        self.function.vars.extend(vars);
        self.function.blocks.extend(blocks);
        self.block = next;
        self.statements = statements;
        Ok(())
    }

    fn tls_index(&mut self, symbol: String) -> Result<String> {
        let index = self.temporary(VarKind::Raw);
        let prefix = self.fresh();
        let (blocks, next) = layout::ensure_tls_index(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            index.clone(),
            symbol,
        )?;
        self.function.blocks.extend(blocks);
        self.block = next;
        Ok(index)
    }

    fn special(&mut self, symbol: Expr, result: Option<String>, value: Option<Expr>) -> Result<()> {
        // The destination may also contain the symbol. Preserve it for the
        // global-value branch before the TLS read overwrites the destination.
        let saved_symbol = self.temporary(VarKind::Obj);
        self.emit(Stmt::Set(saved_symbol.clone(), symbol));
        let prefix = self.fresh();
        let (vars, blocks, next) = layout::special_access(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            saved_symbol,
            result,
            value,
        )?;
        self.function.vars.extend(vars);
        self.function.blocks.extend(blocks);
        self.block = next;
        Ok(())
    }

    fn enter_progv(&mut self, region: usize, symbols: Expr, values: Expr) -> Result<()> {
        let syms = self.temporary(VarKind::Obj);
        let vals = self.temporary(VarKind::Obj);
        let cursor = self.temporary(VarKind::Obj);
        let saved = self.temporary(VarKind::Obj);
        let symbol = self.temporary(VarKind::Obj);
        let pair = self.temporary(VarKind::Obj);
        let value = self.temporary(VarKind::Obj);
        let nil = self.nil();
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
            layout::field_load(Field::Car.id(), var(&cursor))?,
        ));
        self.tls_index(symbol.clone())?;
        self.emit(Stmt::Set(value.clone(), layout::tls_read(var(&symbol))?));
        self.allocate(
            pair.clone(),
            Allocation::Cons,
            vec![var(&symbol), var(&value)],
        )?;
        self.allocate(
            saved.clone(),
            Allocation::Cons,
            vec![var(&pair), var(&saved)],
        )?;
        self.emit(Stmt::Set(
            cursor.clone(),
            layout::field_load(Field::Cdr.id(), var(&cursor))?,
        ));
        self.emit(Stmt::Jump(head));
        self.finish(bind);
        // No binding changes until the complete restoration list is rooted by
        // the entry. The remaining stores cannot allocate or unwind.
        self.statements.extend(layout::enter_dynamic_entry(
            self.slots[region].clone(),
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
            layout::field_load(Field::Car.id(), var(&vals))?,
        ));
        self.emit(Stmt::Set(
            vals.clone(),
            layout::field_load(Field::Cdr.id(), var(&vals))?,
        ));
        self.emit(Stmt::Jump(store.clone()));
        self.finish(store);
        self.emit(layout::tls_write(
            layout::field_load(Field::Car.id(), var(&cursor))?,
            var(value),
        )?);
        self.emit(Stmt::Set(
            cursor.clone(),
            layout::field_load(Field::Cdr.id(), var(&cursor))?,
        ));
        self.emit(Stmt::Jump(head));
        self.finish(done);
        Ok(())
    }

    fn leave_progv(&mut self, region: usize) -> Result<()> {
        let cursor = self.temporary(VarKind::Obj);
        let pair = self.temporary(VarKind::Obj);
        self.emit(layout::progv_bindings(
            cursor.clone(),
            self.slots[region].clone(),
        ));
        let head = self.fresh();
        let body = self.fresh();
        let done = self.fresh();
        let nil = self.nil();
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
            layout::field_load(Field::Car.id(), var(&cursor))?,
        ));
        self.emit(layout::tls_write(
            layout::field_load(Field::Car.id(), var(&pair))?,
            layout::field_load(Field::Cdr.id(), var(&pair))?,
        )?);
        self.emit(Stmt::Set(
            cursor.clone(),
            layout::field_load(Field::Cdr.id(), var(&cursor))?,
        ));
        self.emit(Stmt::Jump(head));
        self.finish(done);
        Ok(())
    }

    fn append_expansion(&mut self, expansion: layout::values::Expansion) {
        let (vars, blocks, next, statements) = expansion;
        self.function.vars.extend(vars);
        self.function.blocks.extend(blocks);
        self.block = next;
        self.statements = statements;
    }
    fn save_values(&mut self, primary: Expr, count: Expr) -> Result<Expr> {
        let result = self.temporary(VarKind::Obj);
        let prefix = self.fresh();
        let handler = self.handler();
        self.imports.insert("kiln_nil".into());
        let expansion = layout::values::pack(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            result.clone(),
            primary,
            count,
            layout::values::Packing::List,
            handler,
        )?;
        self.append_expansion(expansion);
        Ok(var(result))
    }
    fn restore_values(&mut self, saved: Expr, primary: String, count: String) -> Result<()> {
        let prefix = self.fresh();
        self.imports.insert("kiln_nil".into());
        let expansion = layout::values::restore(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            primary,
            count,
            saved,
            None,
            false,
            None,
        )?;
        self.append_expansion(expansion);
        Ok(())
    }

    fn landing(&mut self, result: &str) -> Result<()> {
        let (primary, count) = self.view(result);
        let prefix = self.fresh();
        self.imports.insert("kiln_nil".into());
        let expansion = layout::values::land(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            primary,
            count,
        )?;
        self.append_expansion(expansion);
        Ok(())
    }
    fn error(&mut self, code: i64, value: Expr) -> Result<()> {
        self.error_at(code, value, None)
    }
    fn error_at(&mut self, code: i64, value: Expr, loc: Option<kir::Loc>) -> Result<()> {
        self.imports.insert(kiln_rt::RUNTIME_ERROR_SYMBOL.into());
        self.imports.insert("kiln_undefined_function".into());
        let prefix = self.fresh();
        let handler = self.handler();
        let (vars, blocks, next, statements) = layout::runtime_error(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            code,
            value,
            handler,
            loc,
        )?;
        self.function.vars.extend(vars);
        self.function.blocks.extend(blocks);
        self.block = next;
        self.statements = statements;
        Ok(())
    }

    fn unwind_values(&mut self, target: Expr, view: &str, exit: bool) -> Result<()> {
        let (primary, count) = self.view(view);
        let prefix = self.fresh();
        let handler = self.handler();
        self.imports.extend([
            "kiln_nil".into(),
            kiln_rt::RUNTIME_ERROR_SYMBOL.into(),
            "kiln_undefined_function".into(),
        ]);
        let expansion = layout::values::unwind(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            target,
            var(primary),
            var(count),
            exit,
            handler,
            None,
        )?;
        self.append_expansion(expansion);
        Ok(())
    }
    fn poll(&mut self, entry: bool) -> Result<()> {
        let prefix = self.fresh();
        let handler = self.handler();
        let expansion = layout::poll::expand(
            &prefix,
            self.block.clone(),
            std::mem::take(&mut self.statements),
            entry,
            false,
            handler,
        )?;
        self.append_expansion(expansion);
        self.imports.insert(kiln_rt::STACK_EXHAUSTED_SYMBOL.into());
        Ok(())
    }

    fn expression(&mut self, result: &str, expr: &Expression) -> Result<Expr> {
        use Expression::*;
        Ok(match expr {
            ConstantRef(i) => self.constants[*i].clone(),
            CellRef(i) => layout::cells::load(self.cells.clone(), *i)?,
            Constant(c) => match c {
                super::Constant::Word(n) => Expr::Int(*n),
                super::Constant::F64(bits) => Expr::Int(*bits as i64),
                super::Constant::Fixnum(n) => layout::fixnum_tag(Expr::Int(*n)),
                super::Constant::Character(code) => {
                    layout::character_tag(Expr::Int(i64::from(*code)))
                }
                super::Constant::Single(bits) => {
                    layout::single_float_tag(Expr::Int(i64::from(*bits)))
                }
                super::Constant::Nil => self.nil(),
                super::Constant::True => {
                    self.imports.insert("kiln_t".into());
                    object("kiln_t")
                }
                super::Constant::Unbound => Expr::Int(kiln_rt::object::UNBOUND as i64),
                super::Constant::UnboundSlot => Expr::Int(kiln_rt::object::UNBOUND_SLOT as i64),
            },
            Copy(name) => self.value(name),
            Op(op, args) => {
                if matches!(op, super::Op::UndefinedFunction) {
                    self.imports
                        .insert(layout::builtins::Kind::UndefinedFunction.entry().into());
                    self.imports
                        .insert(layout::builtins::Kind::UndefinedSetfFunction.entry().into());
                }
                self.operation(*op, args)?
            }
            SelfObject => var("self"),
            FramePointer => Expr::Fp,
            ArgumentCount => var("nargs"),
            Argument(i) => var(format!("arg{i}")),
            Literal(i) => layout::cells::load(layout::cells::LITERALS.into(), *i)?,
            Function(name) => object(object_label(name)),
            Capture(index) => layout::closure_ref(var("self"), *index as i64)?,
            Field(field, object) => layout::field_load(field.id(), self.value(object))?,
            Special(symbol) => {
                self.special(self.value(symbol), Some(self.name(result)), None)?;
                self.value(result)
            }
            Test(class, object) => {
                let object = self.value(object);
                if class.immediate() {
                    layout::test_class(class.id(), object)?
                } else {
                    let prefix = self.fresh();
                    let (blocks, next) = layout::guarded_class_test(
                        &prefix,
                        self.block.clone(),
                        std::mem::take(&mut self.statements),
                        self.name(result),
                        class.id(),
                        object,
                    )?;
                    self.function.blocks.extend(blocks);
                    self.block = next;
                    return Ok(self.value(result));
                }
            }
            Select(cond, yes, no) => Expr::Select(
                Box::new(self.value(cond)),
                Box::new(self.value(yes)),
                Box::new(self.value(no)),
            ),
            MvCount(view) => var(self.view(view).1),
            MvRef(view, index) => {
                let (primary, count) = self.view(view);
                let value = if *index == 0 {
                    var(primary)
                } else {
                    layout::secondary_value_ref(Expr::Int(*index as i64))?
                };
                Expr::Select(
                    Box::new(compare(CmpOp::Gt, var(count), Expr::Int(*index as i64))),
                    Box::new(value),
                    Box::new(self.nil()),
                )
            }
        })
    }

    fn operation(&self, op: Op, args: &[String]) -> Result<Expr> {
        use Op::*;
        let a = self.value(&args[0]);
        let b = || self.value(&args[1]);
        Ok(match op {
            WordAdd | WordSub | WordAnd | WordOr | WordXor | WordMul | WordDiv | WordRem
            | WordShl | WordSar | WordShr | F64Add | F64Sub | F64Mul | F64Div | F64Compare => {
                let op = match op {
                    WordAdd => BinOp::Add,
                    WordSub => BinOp::Sub,
                    WordAnd => BinOp::And,
                    WordOr => BinOp::Or,
                    WordXor => BinOp::Xor,
                    WordMul => BinOp::Mul,
                    WordDiv => BinOp::Sdiv,
                    WordRem => BinOp::Srem,
                    WordShl => BinOp::Shlv,
                    WordSar => BinOp::Sarv,
                    WordShr => BinOp::Shrv,
                    F64Compare => BinOp::F64Compare,
                    F64Add => BinOp::F64Add,
                    F64Sub => BinOp::F64Sub,
                    F64Mul => BinOp::F64Mul,
                    _ => BinOp::F64Div,
                };
                Expr::Bin(op, Box::new(a), Box::new(b()))
            }
            WordEq | ObjEq => compare(CmpOp::Eq, a, b()),
            WordLt => compare(CmpOp::Lt, a, b()),
            WordNot => Expr::Bin(BinOp::Xor, Box::new(a), Box::new(Expr::Int(-1))),
            WordNe | ObjNe => compare(CmpOp::Ne, a, b()),
            WordLe => compare(CmpOp::Le, a, b()),
            WordGt => compare(CmpOp::Gt, a, b()),
            WordGe => compare(CmpOp::Ge, a, b()),
            FixnumUnsigned => layout::fixnum_unsigned_bits(a),
            FixnumAnd | FixnumOr | FixnumXor | FixnumDiv | FixnumRem | FixnumEq | FixnumLt
            | FixnumLe | FixnumGt | FixnumGe | FixnumShl | FixnumSar => layout::fixnum_operation(
                match op {
                    FixnumAnd => "fixnum-logand",
                    FixnumOr => "fixnum-logior",
                    FixnumXor => "fixnum-logxor",
                    FixnumDiv => "fixnum-quotient",
                    FixnumRem => "fixnum-remainder",
                    FixnumEq => "fixnum-eq",
                    FixnumLt => "fixnum-lt",
                    FixnumLe => "fixnum-le",
                    FixnumGt => "fixnum-gt",
                    FixnumGe => "fixnum-ge",
                    FixnumShl => "fixnum-shift-left",
                    _ => "fixnum-shift-right",
                },
                a,
                Some(b()),
            )?,
            FixnumNot => Expr::Bin(BinOp::Xor, Box::new(a), Box::new(Expr::Int(-2))),
            FixnumEven | FixnumHalf => layout::fixnum_operation(
                if matches!(op, FixnumEven) {
                    "fixnum-evenp"
                } else {
                    "fixnum-half"
                },
                a,
                None,
            )?,
            SingleTag => layout::single_float_tag(a),
            SingleBits => layout::single_float_bits(a),
            InvalidVectorLength => layout::invalid_vector_length(a),
            InvalidRackLength => layout::invalid_rack_length(a),
            F64Bits | F64FromBits => a,

            FixnumTag => layout::fixnum_tag(a),
            FixnumUntag => layout::fixnum_untag(a),
            FixnumAdd | FixnumSub | FixnumMul => layout::fixnum_arithmetic(
                match op {
                    FixnumAdd => kir::OvfOp::Add,
                    FixnumSub => kir::OvfOp::Sub,
                    _ => kir::OvfOp::Mul,
                },
                a,
                b(),
            ),
            CharacterTag => layout::character_tag(a),
            CharacterUntag => layout::character_untag(a),
            InstanceRack => layout::instance_rack(a)?,
            InstanceClass => layout::instance_class(a)?,
            InstanceStamp => layout::instance_slot(a, Expr::Int(-2))?,
            InstanceSlots => layout::instance_slot(a, Expr::Int(-1))?,
            InstanceSlot => layout::instance_slot(a, b())?,
            StructureLayout => layout::structure_layout(a),
            StructureSlot => layout::structure_slot(a, b()),
            FuncallableFunction => layout::funcallable_function(a),
            UndefinedFunction => layout::builtins::undefined_function(a)?,
            VectorLength => layout::vector_length(a),
            VectorRef => layout::vector_ref(a, b()),
            StringRef => layout::string_ref(a, b()),
            UnboxDouble => layout::field_load(crate::packet::schema::FIELD_DOUBLE_BITS, a)?,
        })
    }

    fn instruction(&mut self, inst: &Instruction) -> Result<()> {
        match inst {
            Instruction::FixnumChecked {
                operation,
                result,
                overflow,
                left,
                right,
            } => {
                self.emit(layout::fixnum_arithmetic_ovf(
                    match operation {
                        FixnumArithmetic::Add => kir::OvfOp::Add,
                        FixnumArithmetic::Sub => kir::OvfOp::Sub,
                        FixnumArithmetic::Mul => kir::OvfOp::Mul,
                    },
                    self.name(result),
                    self.name(overflow),
                    self.value(left),
                    self.value(right),
                ));
            }

            Instruction::Runtime {
                result,
                operation,
                args,
                loc,
                ..
            } => {
                let prefix = self.fresh();
                let handler = if operation.descriptor().safepoint {
                    self.handler()
                } else {
                    None
                };
                let args = self.values(args);
                let (vars, blocks, next, statements) = operation.lower(
                    &prefix,
                    self.block.clone(),
                    std::mem::take(&mut self.statements),
                    self.name(result),
                    args,
                    handler,
                    *loc,
                )?;
                self.function.vars.extend(vars);
                self.function.blocks.extend(blocks);
                self.block = next;
                self.statements = statements;
            }
            Instruction::AllocateSequence {
                result,
                kind,
                length,
                initial,
            } => self.allocate_sequence(
                self.name(result),
                *kind,
                self.value(length),
                self.value(initial),
            )?,
            Instruction::Vector { result, elements } => {
                self.vector(self.name(result), self.values(elements))?
            }
            Instruction::Store(operation, args) => {
                let args = self.values(args);
                let object = args[0].clone();
                let value = args[args.len() - 1].clone();
                let statement = match operation {
                    StoreOperation::Vector => layout::vector_set(object, args[1].clone(), value),
                    StoreOperation::String => layout::string_set(object, args[1].clone(), value),
                    StoreOperation::InstanceRack => layout::set_instance_rack(object, value)?,
                    StoreOperation::InstanceStamp => {
                        layout::set_instance_slot(object, Expr::Int(-2), value)?
                    }
                    StoreOperation::InstanceSlots => {
                        layout::set_instance_slot(object, Expr::Int(-1), value)?
                    }
                    StoreOperation::InstanceSlot => {
                        layout::set_instance_slot(object, args[1].clone(), value)?
                    }
                    StoreOperation::StructureSlot => {
                        layout::set_structure_slot(object, args[1].clone(), value)
                    }
                    StoreOperation::FuncallableFunction => {
                        layout::set_funcallable_function(object, value)
                    }
                };
                self.emit(statement);
            }
            Instruction::AllocateStructure {
                result,
                layout,
                count,
                initial,
            } => {
                self.allocate_indexed_object(
                    self.name(result),
                    self.value(layout),
                    self.value(count),
                    self.value(initial),
                    None,
                )?;
            }
            Instruction::AllocateInstance {
                result,
                funcallable,
                class,
                count,
                stamp,
                slots,
                initial,
            } => {
                self.allocate_indexed_object(
                    self.name(result),
                    self.value(class),
                    self.value(count),
                    self.value(initial),
                    Some((*funcallable, self.value(stamp), self.value(slots))),
                )?;
            }
            Instruction::CellSet(i, value) => self.emit(layout::cells::store(
                self.cells.clone(),
                *i,
                self.value(value),
            )?),
            Instruction::Set(result, expr) => {
                let value = self.expression(result, expr)?;
                self.emit(Stmt::Set(self.name(result), value));
            }
            Instruction::FieldSet(field, object, value) => self.emit(layout::field_store(
                field.id(),
                self.value(object),
                self.value(value),
            )?),
            Instruction::SpecialSet(symbol, value) => {
                self.special(self.value(symbol), None, Some(self.value(value)))?
            }
            Instruction::Numeric {
                result,
                operation,
                args,
                loc,
                ..
            } => {
                let (primary, count) = self.view(result);
                let args = self.values(args);
                let handler = self.handler();
                self.statements
                    .extend(operation.lower(primary, count, args, handler, *loc)?);
            }
            Instruction::Call {
                result,
                entry,
                callee,
                args,
                loc,
                ..
            } => {
                let (v0, nv) = self.view(result);
                let handler = self.handler();
                let mut statements =
                    layout::invoke(v0, nv, self.name(callee), self.values(args), handler, *loc)?;
                if let Some(target) = entry {
                    let Some(Stmt::CallLisp { entry, .. }) = statements.last_mut() else {
                        return Err("missing known invocation".into());
                    };
                    *entry = Expr::Addr(target.clone(), 0);
                }
                self.statements.extend(statements);
            }
            Instruction::CallSpread {
                result,
                callee,
                fixed,
                list,
                loc,
                ..
            } => {
                self.imports.extend([
                    "kiln_nil".into(),
                    kiln_rt::RUNTIME_ERROR_SYMBOL.into(),
                    "kiln_undefined_function".into(),
                ]);
                let prefix = self.fresh();
                let handler = self.handler();
                let (v0, nv) = self.view(result);
                let (vars, blocks, next) = layout::invoke_spread(
                    &prefix,
                    self.block.clone(),
                    std::mem::take(&mut self.statements),
                    v0,
                    nv,
                    self.name(callee),
                    self.values(fixed),
                    self.value(list),
                    handler,
                    *loc,
                )?;
                self.function.vars.extend(vars);
                self.function.blocks.extend(blocks);
                self.block = next;
            }
            Instruction::Values(result, args) => {
                let values = self.values(args);
                self.statements
                    .extend(layout::publish_values(values.clone())?);
                let (v0, nv) = self.view(result);
                let primary = if let Some(primary) = values.first() {
                    primary.clone()
                } else {
                    self.nil()
                };
                self.emit(Stmt::Set(v0, primary));
                self.emit(Stmt::Set(nv, Expr::Int(values.len() as i64)));
            }
            Instruction::Closure {
                result,
                entry,
                fields,
                storage,
            } => {
                let mut values = Vec::new();
                if let Some(fields) = fields {
                    for field in fields {
                        let saved = self.temporary(VarKind::Obj);
                        self.emit(Stmt::Set(saved.clone(), self.value(field)));
                        values.push(var(saved));
                    }
                }
                let count = self
                    .functions
                    .iter()
                    .find(|f| &f.name == entry)
                    .unwrap()
                    .captures;
                if let Storage::Stack(name) = storage {
                    let slot = self.stack_slots[name.as_str()].clone();
                    self.statements.extend(layout::initialize_stack_object(
                        slot.clone(),
                        crate::packet::schema::CLASS_FUNCTION,
                        count as i64,
                    )?);
                    let result = self.name(result);
                    self.statements.extend(layout::initialize_stack_closure(
                        result.clone(),
                        slot,
                        entry.clone(),
                    ));
                    for (index, value) in values.into_iter().enumerate() {
                        self.emit(layout::closure_set(var(&result), index as i64, value)?);
                    }
                    return Ok(());
                }
                let (bytes, header) = layout::closure_layout(count as i64)?;
                let raw = self.temporary(VarKind::Raw);
                let prefix = self.fresh();
                let handler = self.handler();
                let (vars, blocks, next, statements) = layout::allocate_raw(
                    &prefix,
                    self.block.clone(),
                    std::mem::take(&mut self.statements),
                    raw.clone(),
                    Expr::Int(bytes),
                    Expr::Int(header),
                    true,
                    "kiln_rt_alloc".into(),
                    handler,
                )?;
                self.function.vars.extend(vars);
                self.function.blocks.extend(blocks);
                self.block = next;
                self.statements = statements;
                let result = self.name(result);
                self.statements.extend(layout::initialize_closure(
                    result.clone(),
                    raw,
                    entry.clone(),
                ));
                for (index, value) in values.into_iter().enumerate() {
                    self.emit(layout::closure_set(var(&result), index as i64, value)?);
                }
            }
            Instruction::CaptureSet {
                closure,
                index,
                value,
                ..
            } => {
                self.emit(layout::closure_set(
                    self.value(closure),
                    *index as i64,
                    self.value(value),
                )?);
            }
            Instruction::Poll => self.poll(false)?,
            Instruction::Allocate {
                result,
                kind,
                fields,
                storage,
            } => match storage {
                Storage::Heap => self.allocate(self.name(result), *kind, self.values(fields))?,
                Storage::Stack(name) => {
                    let slot = self.stack_slots[name.as_str()].clone();
                    self.statements.extend(layout::initialize_stack_object(
                        slot.clone(),
                        crate::packet::schema::CLASS_CONS,
                        2,
                    )?);
                    self.statements.extend(layout::initialize_stack_cons(
                        self.name(result),
                        Expr::Slot(slot),
                        self.value(&fields[0]),
                        self.value(&fields[1]),
                    ));
                }
            },
            Instruction::ValuesFromList { result, list } => {
                let (primary, count) = self.view(result);
                let prefix = self.fresh();
                let handler = self.handler();
                self.imports.extend([
                    "kiln_nil".into(),
                    kiln_rt::RUNTIME_ERROR_SYMBOL.into(),
                    "kiln_undefined_function".into(),
                ]);
                let expansion = layout::values::restore(
                    &prefix,
                    self.block.clone(),
                    std::mem::take(&mut self.statements),
                    primary,
                    count,
                    self.value(list),
                    None,
                    true,
                    handler,
                )?;
                self.append_expansion(expansion);
            }
            Instruction::MvPush { result, view, acc } => {
                let (primary, count) = self.view(view);
                let prefix = self.fresh();
                let handler = self.handler();
                self.imports.insert("kiln_nil".into());
                let expansion = layout::values::pack(
                    &prefix,
                    self.block.clone(),
                    std::mem::take(&mut self.statements),
                    self.name(result),
                    var(primary),
                    var(count),
                    layout::values::Packing::Reverse(self.value(acc)),
                    handler,
                )?;
                self.append_expansion(expansion);
            }
            Instruction::MvMove { result, view } => {
                let (source, number) = self.view(view);
                let (primary, count) = self.view(result);
                self.emit(Stmt::Set(primary, var(source)));
                self.emit(Stmt::Set(count, var(number)));
            }
            Instruction::MvSave { result, view } => {
                let (primary, count) = self.view(view);
                let saved = self.save_values(var(primary), var(count))?;
                self.emit(Stmt::Set(self.name(result), saved));
            }
            Instruction::MvRestore { result, saved } => {
                let (primary, count) = self.view(result);
                self.restore_values(self.value(saved), primary, count)?;
            }
            Instruction::Enter(name, args) => {
                let region = self.region(name);
                match self.regions[region].kind {
                    RegionKind::StackRoots => {
                        let name = self.regions[region].stack_object.as_ref().unwrap();
                        let object = self.stack_objects.iter().find(|o| &o.name == name).unwrap();
                        let (class, count) = object.shape(self.functions)?;
                        let slot = self.stack_slots[name.as_str()].clone();
                        self.statements.extend(layout::initialize_stack_object(
                            slot.clone(),
                            class,
                            count as i64,
                        )?);
                        self.statements.extend(layout::enter_stack_roots(
                            self.slots[region].clone(),
                            slot,
                            class,
                            count as i64,
                        )?);
                    }
                    RegionKind::Progv => {
                        self.enter_progv(region, self.value(&args[0]), self.value(&args[1]))?
                    }
                    RegionKind::Bind => {
                        let index = self.tls_index(self.name(&args[0]))?;
                        self.statements.extend(layout::enter_dynamic_entry(
                            self.slots[region].clone(),
                            "bind",
                            self.value(&args[0]),
                        )?);
                        let temp = self.temporary(VarKind::Raw);
                        self.statements.extend(layout::bind_special_index(
                            self.slots[region].clone(),
                            temp,
                            var(index),
                            self.value(&args[1]),
                        ));
                    }
                    kind => {
                        let tag = args
                            .first()
                            .map(|arg| self.value(arg))
                            .unwrap_or(Expr::Int(0));
                        self.statements.extend(layout::enter_dynamic_entry(
                            self.slots[region].clone(),
                            kind.name(),
                            tag,
                        )?);
                    }
                }
                self.active.push(ActiveRegion {
                    region,
                    cleanup: false,
                });
            }
            Instruction::Leave(name) => {
                let region = self.region(name);
                match self.regions[region].kind {
                    RegionKind::Bind => {
                        self.emit(layout::unbind_special(self.slots[region].clone()))
                    }
                    RegionKind::Progv => self.leave_progv(region)?,
                    _ => (),
                }
                self.emit(layout::leave_dynamic_entry(self.slots[region].clone()));
                self.active.pop();
            }
            Instruction::Landing { result, .. } => {
                if let Some(result) = result {
                    self.landing(result)?;
                }
            }
        }
        Ok(())
    }

    fn terminator(&mut self, term: &Terminator) -> Result<()> {
        match term {
            Terminator::FatalError { code, value, loc } => {
                self.emit(Stmt::CallRt {
                    name: "kiln_rt_error".into(),
                    results: vec![],
                    args: vec![var("ctx"), self.value(code), self.value(value)],
                    handler: None,
                    loc: *loc,
                });
                self.emit(Stmt::Trap);
                return Ok(());
            }
            Terminator::Error { code, value, loc } => {
                self.error_at(*code, self.value(value), *loc)?;
                return Ok(());
            }
            Terminator::Throw { tag, view } => {
                return self.unwind_values(self.value(tag), view, false);
            }
            Terminator::ExitTo { token, view } => {
                return self.unwind_values(self.value(token), view, true);
            }
            Terminator::ContinueUnwind(name) => {
                let region = self.region(name);
                let handler = self.handler();
                self.statements.extend(layout::values::continue_unwind(
                    self.slots[region].clone(),
                    handler,
                    None,
                ));
                return Ok(());
            }
            _ => (),
        }
        if matches!(
            term,
            Terminator::Return(_) | Terminator::ReturnMv(_) | Terminator::TailCall(..)
        ) {
            self.statements.extend(
                self.rest_roots
                    .iter()
                    .rev()
                    .cloned()
                    .map(layout::leave_dynamic_entry),
            );
        }
        let statements = match term {
            Terminator::Jump(target) => vec![Stmt::Jump(self.blocks[target.as_str()].clone())],
            Terminator::Branch(cond, yes, no) => vec![Stmt::Br(
                self.value(cond),
                self.blocks[yes.as_str()].clone(),
                self.blocks[no.as_str()].clone(),
            )],
            Terminator::Switch(value, default, cases) => vec![Stmt::Switch(
                self.value(value),
                self.blocks[default.as_str()].clone(),
                cases
                    .iter()
                    .map(|(key, target)| (*key, self.blocks[target.as_str()].clone()))
                    .collect(),
            )],
            Terminator::Return(args) => {
                let values = self.values(args);
                let mut statements = layout::publish_values(values.clone())?;
                let primary = if let Some(primary) = values.first() {
                    primary.clone()
                } else {
                    self.nil()
                };
                statements.push(Stmt::Return(primary, Expr::Int(values.len() as i64)));
                statements
            }
            Terminator::ReturnMv(view) => {
                let (v0, nv) = self.view(view);
                vec![Stmt::Return(var(v0), var(nv))]
            }
            Terminator::TailCall(callee, args) => {
                layout::tail_invoke(self.name(callee), self.values(args))?
            }
            Terminator::Trap => vec![Stmt::Trap],
            _ => unreachable!("unwind terminators were lowered above"),
        };
        self.statements.extend(statements);
        Ok(())
    }
}

pub(super) fn module(verified: &Verified<'_>) -> Result<kir::Module> {
    let source = verified.module;
    let mut imports = HashSet::new();
    let mut result = kir::Module {
        name: source.name.clone(),
        inits: vec![object_label(&source.init)],
        shared: HashSet::new(),
        import_funcs: vec![
            ImportFunc {
                name: "kiln_rt_poll".into(),
                params: 2,
                returns: 1,
                unwinds: true,
                noreturn: false,
            },
            ImportFunc {
                name: "kiln_rt_alloc".into(),
                params: 3,
                returns: 1,
                unwinds: true,
                noreturn: false,
            },
        ],
        import_data: vec![],
        data: vec![],
        roots: vec![],
        literal_patches: vec![],
        funcs: vec![],
    };
    for (name, params, noreturn) in [
        ("kiln_rt_throw", 4, false),
        ("kiln_rt_exit_to", 4, false),
        ("kiln_rt_continue_unwind", 2, true),
        ("kiln_rt_error", 3, true),
    ] {
        result.import_funcs.push(ImportFunc {
            name: name.into(),
            params,
            returns: 0,
            unwinds: true,
            noreturn,
        });
    }
    for name in ["kiln_rt_integer_op", "kiln_rt_number_op"] {
        result.import_funcs.push(ImportFunc {
            name: name.into(),
            params: 4,
            returns: 1,
            unwinds: true,
            noreturn: false,
        });
    }
    if source.literals != 0 {
        layout::cells::literals(&mut result, source.literals)?;
    }

    let constants = super::constants::lower(source, &mut result, &mut imports)?;
    super::debug::lower(source, &constants, &mut result, &mut imports);
    for (f, flow) in source.functions.iter().zip(&verified.flow) {
        if f.captures == 0 {
            result.data.push(Data {
                name: object_label(&f.name),
                contents: DataContents::Words(vec![
                    Word::Int(kiln_rt::object::KIND_FUNCTION as i64),
                    Word::FuncAddr(f.name.clone()),
                ]),
            });
        }
        let mut lower = Lowerer {
            constants: &constants,
            cells: super::constants::cell_label(source),
            rest_roots: vec![],
            function: kir::Func {
                name: f.name.clone(),
                vars: vec![],
                labels: vec![],
                slots: vec![],
                blocks: vec![],
                debug: f.debug.as_ref().map(|_| {
                    kir::DebugRef::Direct(Word::DataAddr(
                        super::debug::label(f),
                        kiln_rt::object::TAG_GENERAL as i64,
                    ))
                }),
            },
            names: HashMap::new(),
            blocks: HashMap::new(),
            imports: &mut imports,
            regions: &f.regions,
            functions: &source.functions,
            slots: (0..f.regions.len()).map(|i| format!("r{i}")).collect(),
            stack_slots: f
                .stack_objects
                .iter()
                .enumerate()
                .map(|(i, o)| (o.name.as_str(), format!("o{i}")))
                .collect(),
            stack_objects: &f.stack_objects,
            active: vec![],
            handlers: vec![],
            block: "entry".into(),
            statements: vec![],
            next: 0,
        };
        for (i, (name, ty)) in f.vars.iter().enumerate() {
            let renamed = format!("v{i}");
            lower.names.insert(name, renamed.clone());
            if *ty == Type::Mv {
                lower
                    .function
                    .vars
                    .push((format!("{renamed}_primary"), VarKind::Obj));
                lower
                    .function
                    .vars
                    .push((format!("{renamed}_count"), VarKind::Raw));
            } else {
                lower.function.vars.push((
                    renamed,
                    match ty {
                        Type::Obj => VarKind::Obj,
                        Type::F64 => VarKind::F64,
                        _ => VarKind::Raw,
                    },
                ));
            }
        }
        if let Some(debug) = &f.debug {
            lower.function.labels = debug
                .variables
                .iter()
                .enumerate()
                .map(|(i, var)| (lower.name(&var.variable), i as u32))
                .collect();
        }
        for (i, block) in f.blocks.iter().enumerate() {
            lower.blocks.insert(&block.name, format!("b{i}"));
        }
        for slot in &lower.slots {
            lower
                .function
                .slots
                .push((slot.clone(), size_of::<kiln_rt::context::DynEntry>() as u32));
        }
        for object in &f.stack_objects {
            let (class, count) = object.shape(&source.functions)?;
            let (bytes, _, _) = layout::stack_object_layout(class, count as i64)?;
            lower
                .function
                .slots
                .push((lower.stack_slots[object.name.as_str()].clone(), bytes));
        }
        // Copy incoming object arguments before a poll or an outgoing call can
        // overwrite the transfer area. Missing optional slots are safe NIL roots.
        let received = (0..f.receive)
            .map(|i| format!("arg{i}"))
            .collect::<Vec<_>>();
        for name in &received {
            lower.function.vars.push((name.clone(), VarKind::Obj));
        }
        if !received.is_empty() {
            lower.imports.insert("kiln_nil".into());
        }
        lower
            .statements
            .extend(layout::arguments::receive_prefix(&received, None)?);
        if let Some(rest) = &f.rest {
            let mut slots = Vec::new();
            for i in 0..rest.stack_capacity {
                let slot = format!("rest_cons_{i}");
                let root = format!("rest_root_{i}");
                lower
                    .function
                    .slots
                    .push((slot.clone(), kiln_rt::object::CONS_BYTES as u32));
                lower
                    .function
                    .slots
                    .push((root.clone(), size_of::<kiln_rt::context::DynEntry>() as u32));
                lower.statements.extend(layout::initialize_stack_object(
                    slot.clone(),
                    crate::packet::schema::CLASS_CONS,
                    2,
                )?);
                lower.statements.extend(layout::enter_stack_roots(
                    root.clone(),
                    slot.clone(),
                    crate::packet::schema::CLASS_CONS,
                    2,
                )?);
                lower.rest_roots.push(root);
                slots.push(slot);
            }
            lower.imports.insert("kiln_nil".into());
            let prefix = lower.fresh();
            let (vars, blocks, next, statements) = layout::arguments::rest_list(
                &prefix,
                lower.block.clone(),
                std::mem::take(&mut lower.statements),
                lower.name(&rest.variable),
                rest.first,
                (0..kir::REG_ARGS).map(|i| var(format!("a{i}"))).collect(),
                &slots,
                None,
            )?;
            lower.function.vars.extend(vars);
            lower.function.blocks.extend(blocks);
            lower.block = next;
            lower.statements = statements;
        }
        lower.poll(true)?;
        lower.emit(Stmt::Jump(lower.blocks[f.blocks[0].name.as_str()].clone()));
        lower.finish(String::new());
        for (i, block) in f.blocks.iter().enumerate() {
            let Some(active) = &flow.entries[i] else {
                continue;
            };
            lower.active = active.clone();
            lower.block = lower.blocks[block.name.as_str()].clone();
            if flow.polls[i] {
                lower.poll(false)?;
            }
            for inst in &block.instructions {
                lower.instruction(inst)?;
            }
            lower.terminator(&block.terminator)?;
            lower.finish(String::new());
        }
        lower.dispatchers()?;
        result.funcs.push(lower.function);
    }
    super::runtime::register_imports(&mut result)?;
    imports.retain(|name| !result.data.iter().any(|d| &d.name == name));
    result.import_data = imports.into_iter().collect();
    result.import_data.sort();
    for (kind, image) in &source.builtins {
        layout::builtins::install(&mut result, *kind, *image)?;
    }
    layout::builtins::register_error_imports(&mut result)?;
    layout::poll::register(&mut result)?;
    layout::register_tls_import(&mut result)?;
    Ok(result)
}
