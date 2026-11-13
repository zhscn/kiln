use super::*;
use std::collections::{HashMap, HashSet, VecDeque};

const ARGUMENT_LIMIT: usize = kir::REG_ARGS + kiln_rt::context::VALUES_MAX;
const VALUE_LIMIT: usize = 1 + kiln_rt::context::VALUES_MAX;

pub(super) fn module(module: &Module) -> Result<Verified<'_>> {
    if module.name.is_empty() || module.name.contains('\0') {
        return Err("LIR: invalid module name".into());
    }
    if module.literals > crate::packet::schema::MAX_BYTES as usize / 16 {
        return Err("LIR: literal table exceeds request limit".into());
    }
    let mut builtins = HashSet::new();
    for (kind, _) in &module.builtins {
        if !builtins.insert(*kind) {
            return Err("LIR: duplicate builtin declaration".into());
        }
    }
    super::constants::verify(module)?;
    super::debug::verify(module)?;
    let mut functions = HashSet::new();
    for f in &module.functions {
        if f.name.is_empty()
            || f.name.contains('\0')
            || [
                "_kiln_lir_",
                "kiln_rt_",
                "kiln_sym_",
                "kiln_name_",
                "kiln_undef_",
                "kiln_pkg_",
            ]
            .iter()
            .any(|prefix| f.name.starts_with(prefix))
            || [
                "kiln_nil",
                "kiln_t",
                "kiln_literals",
                "kiln_rt_poll",
                "kiln_rt_alloc",
                "kiln_rt_throw",
                "kiln_rt_exit_to",
                "kiln_rt_continue_unwind",
                "kiln_rt_error",
                "kiln_rt_tls_index",
                "kiln_undefined_function",
                "kiln_undefined_setf_function",
                "kiln_funcallable_trampoline",
                "kiln_funcallable_unset_fobj",
                "kiln_sym_KEYWORD_3A_CELL",
                "kiln_sym_KEYWORD_3A_DOUBLE_2D_BITS",
                kiln_rt::STACK_EXHAUSTED_SYMBOL,
                kiln_rt::RUNTIME_ERROR_SYMBOL,
            ]
            .contains(&f.name.as_str())
        {
            return Err(format!("LIR: invalid or reserved function name {}", f.name));
        }
        if !functions.insert(f.name.as_str()) {
            return Err(format!("LIR: duplicate function {}", f.name));
        }
    }
    if !functions.contains(module.init.as_str()) {
        return Err("LIR: init function is not defined".into());
    }
    if module
        .functions
        .iter()
        .any(|f| f.name == module.init && f.captures != 0)
    {
        return Err("LIR: init function cannot require captures".into());
    }
    let flow = module
        .functions
        .iter()
        .map(|f| {
            function(f, module, &functions)
                .map_err(|error| format!("LIR function {}: {error}", f.name))
        })
        .collect::<Result<_>>()?;
    Ok(Verified { module, flow })
}

struct Types<'a> {
    vars: HashMap<&'a str, Type>,
}
impl Types<'_> {
    fn get(&self, name: &str) -> Result<Type> {
        self.vars
            .get(name)
            .copied()
            .ok_or_else(|| format!("undeclared variable {name}"))
    }
    fn expect(&self, name: &str, ty: Type) -> Result<()> {
        let actual = self.get(name)?;
        if actual == ty {
            Ok(())
        } else {
            Err(format!("variable {name}: expected {ty:?}, got {actual:?}"))
        }
    }
    fn objects(&self, vars: &[String], limit: usize) -> Result<()> {
        if vars.len() > limit {
            return Err("too many arguments or values".into());
        }
        for var in vars {
            self.expect(var, Type::Obj)?;
        }
        Ok(())
    }
}

fn expression(
    expr: &Expression,
    types: &Types<'_>,
    f: &Function,
    module: &Module,
    functions: &HashSet<&str>,
) -> Result<Type> {
    use Expression::*;
    Ok(match expr {
        CellRef(i) => {
            if *i >= module.cells.len() {
                return Err("cell index out of range".into());
            }
            Type::Obj
        }
        ConstantRef(i) => {
            if *i >= module.constants.len() {
                return Err("constant index out of range".into());
            }
            Type::Obj
        }
        Constant(c) => match c {
            super::Constant::Word(_) => Type::Word,
            super::Constant::F64(_) => Type::F64,
            super::Constant::Fixnum(n) => {
                if !(kiln_rt::object::FIXNUM_MIN..=kiln_rt::object::FIXNUM_MAX).contains(n) {
                    return Err("fixnum constant out of range".into());
                }
                Type::Obj
            }
            super::Constant::Character(code) => {
                if *code >= 0x110000 {
                    return Err("character constant out of range".into());
                }
                Type::Obj
            }
            _ => Type::Obj,
        },
        Copy(name) => {
            let ty = types.get(name)?;
            if ty == Type::Mv {
                return Err("multiple-value views cannot be copied".into());
            }
            ty
        }
        Op(op, args) => {
            let (inputs, output) = op.signature();
            if inputs.len() != args.len() {
                return Err("wrong operation arity".into());
            }
            for (name, ty) in args.iter().zip(inputs) {
                types.expect(name, *ty)?;
            }
            output
        }
        SelfObject | FramePointer => Type::Obj,
        ArgumentCount => Type::Word,
        Argument(i) => {
            if *i >= f.receive {
                return Err("argument index exceeds receive declaration".into());
            }
            Type::Obj
        }
        Literal(i) => {
            if *i >= module.literals {
                return Err("literal index out of range".into());
            }
            Type::Obj
        }
        Function(name) => {
            if !functions.contains(name.as_str()) {
                return Err(format!("undefined function {name}"));
            }
            if function_captures(module, name)? != 0 {
                return Err("captured function requires a closure".into());
            }
            Type::Obj
        }
        Capture(index) => {
            if *index >= f.captures {
                return Err("capture index out of range".into());
            }
            Type::Obj
        }
        Special(symbol) => {
            types.expect(symbol, Type::Obj)?;
            Type::Obj
        }
        Field(_, object) | Test(_, object) => {
            types.expect(object, Type::Obj)?;
            if matches!(expr, Test(..)) {
                Type::Word
            } else {
                Type::Obj
            }
        }
        Select(cond, yes, no) => {
            types.expect(cond, Type::Word)?;
            let ty = types.get(yes)?;
            types.expect(no, ty)?;
            if ty == Type::Mv {
                return Err("multiple-value views cannot be selected".into());
            }
            ty
        }
        MvCount(view) => {
            types.expect(view, Type::Mv)?;
            Type::Word
        }
        MvRef(view, i) => {
            types.expect(view, Type::Mv)?;
            if *i >= VALUE_LIMIT {
                return Err("multiple-value index out of range".into());
            }
            Type::Obj
        }
    })
}

fn instruction(
    inst: &Instruction,
    types: &Types<'_>,
    f: &Function,
    module: &Module,
    functions: &HashSet<&str>,
) -> Result<()> {
    match inst {
        Instruction::Runtime {
            result,
            operation,
            args,
            loc,
            region,
        } => {
            let descriptor = operation.descriptor();
            types.expect(result, Type::Obj)?;
            types.objects(args, descriptor.arguments)?;
            if args.len() != descriptor.arguments {
                return Err("wrong runtime operation arity".into());
            }
            if loc.is_some_and(|(start, end)| start > end) {
                return Err("reversed runtime location".into());
            }
            if let Some(region) = region {
                find_region(f, region)?;
            }
        }
        Instruction::AllocateRack {
            result,
            class,
            count,
        } => {
            types.expect(result, Type::Obj)?;
            types.expect(class, Type::Obj)?;
            types.expect(count, Type::Word)?;
        }
        Instruction::AllocateFuncallable { result, rack } => {
            types.expect(result, Type::Obj)?;
            types.expect(rack, Type::Obj)?;
        }
        Instruction::AllocateSymbol { result, name } => {
            types.expect(result, Type::Obj)?;
            types.expect(name, Type::Obj)?;
        }
        Instruction::AllocateUndefined { result, symbol, .. } => {
            types.expect(result, Type::Obj)?;
            types.expect(symbol, Type::Obj)?;
        }
        Instruction::AllocateSequence {
            result,
            length,
            initial,
            ..
        } => {
            types.expect(result, Type::Obj)?;
            types.expect(length, Type::Word)?;
            types.expect(initial, Type::Obj)?;
        }
        Instruction::Vector { result, elements } => {
            types.expect(result, Type::Obj)?;
            types.objects(elements, crate::packet::schema::MAX_BYTES as usize / 16)?;
        }
        Instruction::Store(operation, args) => {
            let signature = operation.signature();
            if signature.len() != args.len() {
                return Err("wrong store operation arity".into());
            }
            for (arg, ty) in args.iter().zip(signature) {
                types.expect(arg, *ty)?;
            }
        }
        Instruction::AllocateStructure {
            result,
            layout,
            count,
            initial,
        } => {
            types.expect(result, Type::Obj)?;
            types.expect(layout, Type::Obj)?;
            types.expect(count, Type::Word)?;
            types.expect(initial, Type::Obj)?;
        }
        Instruction::AllocateInstance {
            result,
            class,
            count,
            stamp,
            slots,
            initial,
            ..
        } => {
            types.expect(result, Type::Obj)?;
            types.expect(count, Type::Word)?;
            for value in [class, stamp, slots, initial] {
                types.expect(value, Type::Obj)?;
            }
        }
        Instruction::CellSet(i, value) => {
            if *i >= module.cells.len() {
                return Err("cell index out of range".into());
            }
            types.expect(value, Type::Obj)?;
        }
        Instruction::Set(dst, expr) => {
            types.expect(dst, expression(expr, types, f, module, functions)?)?
        }
        Instruction::FieldSet(_, object, value) | Instruction::SpecialSet(object, value) => {
            types.expect(object, Type::Obj)?;
            types.expect(value, Type::Obj)?;
        }
        Instruction::Numeric {
            result,
            operation,
            args,
            loc,
            region,
        } => {
            if let Some(region) = region {
                find_region(f, region)?;
            }
            if loc.is_some_and(|(start, end)| start > end) {
                return Err("reversed call location".into());
            }
            types.expect(result, Type::Mv)?;
            if args.len() != operation.signature().2 {
                return Err("wrong numeric operation arity".into());
            }
            types.objects(args, ARGUMENT_LIMIT)?;
        }
        Instruction::Call {
            result,
            callee,
            args,
            loc,
            region,
            ..
        }
        | Instruction::CallSpread {
            result,
            callee,
            fixed: args,
            loc,
            region,
            ..
        } => {
            if let Some(region) = region {
                find_region(f, region)?;
            }
            if loc.is_some_and(|(start, end)| start > end) {
                return Err("reversed call location".into());
            }
            types.expect(result, Type::Mv)?;
            types.expect(callee, Type::Obj)?;
            types.objects(args, ARGUMENT_LIMIT)?;
            if let Instruction::Call {
                entry: Some(entry), ..
            } = inst
                && !functions.contains(entry.as_str())
            {
                return Err("known call entry is not defined".into());
            }
            if let Instruction::CallSpread { list, .. } = inst {
                types.expect(list, Type::Obj)?;
            }
        }
        Instruction::Values(result, args) => {
            types.expect(result, Type::Mv)?;
            types.objects(args, VALUE_LIMIT)?;
        }
        Instruction::Closure {
            result,
            entry,
            fields,
            storage,
        } => {
            if let Storage::Stack(name) = storage {
                let object = find_stack_object(f, name)?;
                if !matches!(&object.kind, StackKind::Closure(expected) if expected == entry) {
                    return Err("stack closure does not match its declared entry".into());
                }
            }
            types.expect(result, Type::Obj)?;
            let count = function_captures(module, entry)?;
            if let Some(fields) = fields {
                if fields.len() != count {
                    return Err("closure capture count does not match entry".into());
                }
                types.objects(fields, count)?;
            }
        }
        Instruction::CaptureSet {
            closure,
            entry,
            index,
            value,
        } => {
            types.expect(closure, Type::Obj)?;
            types.expect(value, Type::Obj)?;
            if *index >= function_captures(module, entry)? {
                return Err("capture index out of range".into());
            }
        }
        Instruction::FixnumChecked {
            result,
            overflow,
            left,
            right,
            ..
        } => {
            types.expect(result, Type::Obj)?;
            types.expect(overflow, Type::Word)?;
            types.expect(left, Type::Obj)?;
            types.expect(right, Type::Obj)?;
        }
        Instruction::ValuesFromList { result, list } => {
            types.expect(result, Type::Mv)?;
            types.expect(list, Type::Obj)?;
        }
        Instruction::MvPush { result, view, acc } => {
            types.expect(result, Type::Obj)?;
            types.expect(view, Type::Mv)?;
            types.expect(acc, Type::Obj)?;
        }
        Instruction::MvMove { result, view } => {
            types.expect(result, Type::Mv)?;
            types.expect(view, Type::Mv)?;
        }
        Instruction::MvSave { result, view } => {
            types.expect(result, Type::Obj)?;
            types.expect(view, Type::Mv)?;
        }
        Instruction::MvRestore { result, saved } => {
            types.expect(result, Type::Mv)?;
            types.expect(saved, Type::Obj)?;
        }
        Instruction::Enter(region, args) => {
            let region = find_region(f, region)?;
            let count = match f.regions[region].kind {
                RegionKind::UnwindProtect => 0,
                RegionKind::Catch | RegionKind::ExitPoint => 1,
                RegionKind::Bind | RegionKind::Progv => 2,
                RegionKind::StackRoots => 0,
            };
            if args.len() != count {
                return Err("wrong region argument count".into());
            }
            types.objects(args, count)?;
        }
        Instruction::Leave(region) => {
            find_region(f, region)?;
        }
        Instruction::Landing { region, result } => {
            let region = find_region(f, region)?;
            if !f.regions[region].kind.has_handler() {
                return Err("binding regions have no landing".into());
            }
            if result.is_some() == (f.regions[region].kind == RegionKind::UnwindProtect) {
                return Err("landing result does not match region kind".into());
            }
            if let Some(result) = result {
                types.expect(result, Type::Mv)?;
            }
        }
        Instruction::Allocate {
            result,
            kind,
            fields,
            storage,
        } => {
            if let Storage::Stack(name) = storage {
                let object = find_stack_object(f, name)?;
                if !matches!((&object.kind, kind), (StackKind::Cons, Allocation::Cons)) {
                    return Err("stack allocation does not match its declared object kind".into());
                }
            }
            types.expect(result, Type::Obj)?;
            if fields.len() != kind.fields().len() {
                return Err("wrong allocation field count".into());
            }
            for (field, ty) in fields.iter().zip(kind.fields()) {
                types.expect(field, *ty)?;
            }
        }
        Instruction::Poll => (),
    }
    Ok(())
}

fn terminator(term: &Terminator, types: &Types<'_>, f: &Function) -> Result<()> {
    match term {
        Terminator::FatalError { code, value, loc } => {
            types.expect(code, Type::Word)?;
            types.expect(value, Type::Obj)?;
            if loc.is_some_and(|(start, end)| start > end) {
                return Err("reversed fatal error location".into());
            }
        }
        Terminator::Error { code, value, loc } => {
            if !(1..=kiln_rt::rtfun::ERR_EXPIRED_EXIT as i64).contains(code) {
                return Err("unknown error code".into());
            }
            if loc.is_some_and(|(start, end)| start > end) {
                return Err("reversed error location".into());
            }
            types.expect(value, Type::Obj)?;
        }
        Terminator::Branch(cond, ..) => types.expect(cond, Type::Word)?,
        Terminator::Switch(value, _, cases) => {
            types.expect(value, Type::Word)?;
            let mut keys = HashSet::new();
            for (key, _) in cases {
                if !keys.insert(key) {
                    return Err("duplicate switch key".into());
                }
            }
        }
        Terminator::Return(values) => types.objects(values, VALUE_LIMIT)?,
        Terminator::ReturnMv(view) => types.expect(view, Type::Mv)?,
        Terminator::TailCall(callee, args) => {
            types.expect(callee, Type::Obj)?;
            types.objects(args, ARGUMENT_LIMIT)?;
        }
        Terminator::Throw { tag, view } | Terminator::ExitTo { token: tag, view } => {
            types.expect(tag, Type::Obj)?;
            types.expect(view, Type::Mv)?;
        }
        Terminator::ContinueUnwind(region) => {
            let region = find_region(f, region)?;
            if f.regions[region].kind != RegionKind::UnwindProtect {
                return Err("continue-unwind requires unwind-protect".into());
            }
        }
        _ => (),
    }
    Ok(())
}

fn successors(term: &Terminator) -> Vec<&str> {
    match term {
        Terminator::Jump(target) => vec![target],
        Terminator::Branch(_, yes, no) => vec![yes, no],
        Terminator::Switch(_, default, cases) => std::iter::once(default.as_str())
            .chain(cases.iter().map(|(_, target)| target.as_str()))
            .collect(),
        _ => vec![],
    }
}

// Removing all DFS back edges leaves a DAG. Polling their targets therefore
// covers every cycle, even when a strongly connected component has many entries.
fn loop_polls(edges: &[Vec<usize>]) -> Vec<bool> {
    let mut color = vec![0; edges.len()];
    let mut polls = vec![false; edges.len()];
    let mut stack = vec![(0, 0)];
    color[0] = 1;
    while let Some((node, next)) = stack.last_mut() {
        if *next == edges[*node].len() {
            color[*node] = 2;
            stack.pop();
            continue;
        }
        let target = edges[*node][*next];
        *next += 1;
        match color[target] {
            0 => {
                color[target] = 1;
                stack.push((target, 0));
            }
            1 => polls[target] = true,
            _ => (),
        }
    }
    polls
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
struct State {
    initialized: HashSet<String>,
    view: Option<String>,
}

impl State {
    fn merge(&mut self, other: &Self) -> bool {
        let old_len = self.initialized.len();
        self.initialized
            .retain(|name| other.initialized.contains(name));
        let view_changed = self.view.is_some() && self.view != other.view;
        if view_changed {
            self.view = None;
        }
        old_len != self.initialized.len() || view_changed
    }
    fn use_var(&self, name: &str) -> Result<()> {
        if !self.initialized.contains(name) {
            return Err(format!("variable {name} is not initialized on every path"));
        }
        Ok(())
    }
    fn use_view(&self, name: &str) -> Result<()> {
        self.use_var(name)?;
        if self.view.as_deref() != Some(name) {
            return Err(format!("multiple-value view {name} has expired"));
        }
        Ok(())
    }
    fn step(&mut self, inst: &Instruction, f: &Function) {
        match inst {
            Instruction::Runtime {
                result, operation, ..
            } => {
                self.initialized.insert(result.clone());
                if operation.descriptor().safepoint {
                    self.view = None;
                }
            }
            Instruction::AllocateRack { result: dst, .. }
            | Instruction::AllocateFuncallable { result: dst, .. }
            | Instruction::AllocateSymbol { result: dst, .. }
            | Instruction::AllocateUndefined { result: dst, .. }
            | Instruction::AllocateStructure { result: dst, .. }
            | Instruction::AllocateInstance { result: dst, .. }
            | Instruction::AllocateSequence { result: dst, .. }
            | Instruction::Vector { result: dst, .. } => {
                self.initialized.insert(dst.clone());
                self.view = None;
            }
            Instruction::FixnumChecked {
                result, overflow, ..
            } => {
                self.initialized.insert(result.clone());
                self.initialized.insert(overflow.clone());
            }
            Instruction::Set(dst, _) => {
                self.initialized.insert(dst.clone());
            }
            Instruction::Values(dst, _)
            | Instruction::Call { result: dst, .. }
            | Instruction::Numeric { result: dst, .. }
            | Instruction::CallSpread { result: dst, .. } => {
                self.initialized.insert(dst.clone());
                self.view = Some(dst.clone());
            }
            Instruction::MvMove { result, .. }
            | Instruction::ValuesFromList { result, .. }
            | Instruction::MvRestore { result, .. }
            | Instruction::Landing {
                result: Some(result),
                ..
            } => {
                self.initialized.insert(result.clone());
                self.view = Some(result.clone());
            }
            Instruction::MvPush { result, .. } | Instruction::MvSave { result, .. } => {
                self.initialized.insert(result.clone());
                self.view = None;
            }
            Instruction::Poll => self.view = None,
            Instruction::Enter(region, _)
                if f.regions[find_region(f, region).unwrap()].kind == RegionKind::Progv =>
            {
                self.view = None
            }
            Instruction::Allocate {
                result, storage, ..
            }
            | Instruction::Closure {
                result, storage, ..
            } => {
                self.initialized.insert(result.clone());
                if matches!(storage, Storage::Heap) {
                    self.view = None;
                }
            }
            _ => (),
        }
    }
    fn check_instruction(&self, inst: &Instruction) -> Result<()> {
        match inst {
            Instruction::AllocateRack { class, count, .. } => {
                self.use_var(class)?;
                self.use_var(count)?;
            }
            Instruction::AllocateFuncallable { rack, .. } => self.use_var(rack)?,
            Instruction::AllocateSymbol { name, .. } => self.use_var(name)?,
            Instruction::AllocateUndefined { symbol, .. } => self.use_var(symbol)?,
            Instruction::AllocateSequence {
                length, initial, ..
            } => {
                self.use_var(length)?;
                self.use_var(initial)?;
            }
            Instruction::Vector { elements, .. } => {
                for element in elements {
                    self.use_var(element)?;
                }
            }
            Instruction::Store(_, args) => {
                for arg in args {
                    self.use_var(arg)?;
                }
            }
            Instruction::AllocateStructure {
                layout,
                count,
                initial,
                ..
            } => {
                for arg in [layout, count, initial] {
                    self.use_var(arg)?;
                }
            }
            Instruction::AllocateInstance {
                class,
                count,
                stamp,
                slots,
                initial,
                ..
            } => {
                for arg in [class, count, stamp, slots, initial] {
                    self.use_var(arg)?;
                }
            }
            Instruction::CellSet(_, value) => self.use_var(value)?,
            Instruction::Set(_, expr) => match expr {
                Expression::Copy(var)
                | Expression::Field(_, var)
                | Expression::Test(_, var)
                | Expression::Special(var) => self.use_var(var)?,
                Expression::Op(_, args) => {
                    for arg in args {
                        self.use_var(arg)?;
                    }
                }
                Expression::Select(cond, yes, no) => {
                    for var in [cond, yes, no] {
                        self.use_var(var)?;
                    }
                }
                Expression::MvCount(view) | Expression::MvRef(view, _) => self.use_view(view)?,
                _ => (),
            },
            Instruction::FixnumChecked { left, right, .. } => {
                self.use_var(left)?;
                self.use_var(right)?;
            }
            Instruction::FieldSet(_, object, value) | Instruction::SpecialSet(object, value) => {
                self.use_var(object)?;
                self.use_var(value)?;
            }
            Instruction::Runtime { args, .. } | Instruction::Numeric { args, .. } => {
                for arg in args {
                    self.use_var(arg)?;
                }
            }
            Instruction::Call { callee, args, .. }
            | Instruction::CallSpread {
                callee,
                fixed: args,
                ..
            } => {
                self.use_var(callee)?;
                for arg in args {
                    self.use_var(arg)?;
                }
                if let Instruction::CallSpread { list, .. } = inst {
                    self.use_var(list)?;
                }
            }
            Instruction::Values(_, args) => {
                for arg in args {
                    self.use_var(arg)?;
                }
            }
            Instruction::Allocate { fields, .. } => {
                for field in fields {
                    self.use_var(field)?;
                }
            }
            Instruction::Closure { fields, .. } => {
                if let Some(fields) = fields {
                    for field in fields {
                        self.use_var(field)?;
                    }
                }
            }
            Instruction::CaptureSet { closure, value, .. } => {
                self.use_var(closure)?;
                self.use_var(value)?;
            }
            Instruction::ValuesFromList { list, .. } => self.use_var(list)?,
            Instruction::MvPush { view, acc, .. } => {
                self.use_view(view)?;
                self.use_var(acc)?;
            }
            Instruction::MvMove { view, .. } | Instruction::MvSave { view, .. } => {
                self.use_view(view)?
            }
            Instruction::MvRestore { saved, .. } => self.use_var(saved)?,
            Instruction::Enter(_, args) => {
                for arg in args {
                    self.use_var(arg)?;
                }
            }
            Instruction::Leave(_) | Instruction::Landing { .. } => (),
            Instruction::Poll => (),
        }
        Ok(())
    }
    fn check_terminator(&self, term: &Terminator) -> Result<()> {
        match term {
            Terminator::Branch(cond, ..) | Terminator::Switch(cond, ..) => self.use_var(cond)?,
            Terminator::Return(args) => {
                for arg in args {
                    self.use_var(arg)?;
                }
            }
            Terminator::ReturnMv(view) => self.use_view(view)?,
            Terminator::TailCall(callee, args) => {
                self.use_var(callee)?;
                for arg in args {
                    self.use_var(arg)?;
                }
            }
            Terminator::FatalError { code, value, .. } => {
                self.use_var(code)?;
                self.use_var(value)?;
            }
            Terminator::Error { value, .. } => self.use_var(value)?,
            Terminator::Throw { tag, view } | Terminator::ExitTo { token: tag, view } => {
                self.use_var(tag)?;
                self.use_view(view)?;
            }
            _ => (),
        }
        Ok(())
    }
}

fn find_region(f: &Function, name: &str) -> Result<usize> {
    f.regions
        .iter()
        .position(|r| r.name == name)
        .ok_or_else(|| format!("undefined region {name}"))
}

fn function_captures(module: &Module, name: &str) -> Result<usize> {
    module
        .functions
        .iter()
        .find(|f| f.name == name)
        .map(|f| f.captures)
        .ok_or_else(|| format!("undefined function {name}"))
}

fn find_stack_object<'a>(f: &'a Function, name: &str) -> Result<&'a StackObject> {
    f.stack_objects
        .iter()
        .find(|object| object.name == name)
        .ok_or_else(|| format!("undefined stack object {name}"))
}

fn may_unwind(inst: &Instruction, f: &Function) -> bool {
    matches!(inst,Instruction::Runtime {operation,..} if operation.descriptor().safepoint)
        || matches!(
            inst,
            Instruction::AllocateRack { .. }
                | Instruction::AllocateFuncallable { .. }
                | Instruction::AllocateSymbol { .. }
                | Instruction::AllocateUndefined { .. }
                | Instruction::AllocateStructure { .. }
                | Instruction::AllocateInstance { .. }
                | Instruction::AllocateSequence { .. }
                | Instruction::Vector { .. }
                | Instruction::Numeric { .. }
                | Instruction::Call { .. }
                | Instruction::CallSpread { .. }
                | Instruction::Allocate {
                    storage: Storage::Heap,
                    ..
                }
                | Instruction::Closure {
                    storage: Storage::Heap,
                    ..
                }
                | Instruction::ValuesFromList { .. }
                | Instruction::MvPush { .. }
                | Instruction::MvSave { .. }
                | Instruction::Poll
        )
        || matches!(inst, Instruction::Enter(region, _) if f.regions[find_region(f, region).unwrap()].kind == RegionKind::Progv)
}

struct UnwindEdge {
    at: usize,
    target: usize,
}
struct RegionFlow {
    entries: Vec<Option<Vec<ActiveRegion>>>,
    unwinds: Vec<Vec<UnwindEdge>>,
    graph: Vec<Vec<usize>>,
}

fn region_flow(
    f: &Function,
    normal: &[Vec<usize>],
    blocks: &HashMap<&str, usize>,
    polls: &[bool],
) -> Result<RegionFlow> {
    let mut flow = RegionFlow {
        entries: vec![None; f.blocks.len()],
        unwinds: (0..f.blocks.len()).map(|_| Vec::new()).collect(),
        graph: normal.to_vec(),
    };
    flow.entries[0] = Some(vec![]);
    let mut work = VecDeque::from([0]);
    fn enter_block(
        flow: &mut RegionFlow,
        work: &mut VecDeque<usize>,
        f: &Function,
        target: usize,
        active: &[ActiveRegion],
    ) -> Result<()> {
        if let Some(old) = &flow.entries[target] {
            if old != active {
                return Err(format!(
                    "inconsistent region stack at block {}",
                    f.blocks[target].name
                ));
            }
        } else {
            flow.entries[target] = Some(active.to_vec());
            work.push_back(target);
        }
        Ok(())
    }
    fn unwind(
        flow: &mut RegionFlow,
        work: &mut VecDeque<usize>,
        f: &Function,
        blocks: &HashMap<&str, usize>,
        source: usize,
        at: usize,
        active: &[ActiveRegion],
    ) -> Result<()> {
        // A call may target any enclosing handler. The backend dispatcher
        // routes the runtime payload, and the unwinder removes intervening
        // entries or leaves an unwind-protect linked in cleanup mode.
        for (j, entry) in active.iter().enumerate().rev() {
            if entry.cleanup || !f.regions[entry.region].kind.has_handler() {
                continue;
            }
            let region = &f.regions[entry.region];
            let target = blocks[region.landing.as_ref().unwrap().as_str()];
            let mut landed = active[..j].to_vec();
            if region.kind == RegionKind::UnwindProtect {
                landed.push(ActiveRegion {
                    region: entry.region,
                    cleanup: true,
                });
            }
            enter_block(flow, work, f, target, &landed)?;
            flow.unwinds[source].push(UnwindEdge { at, target });
            flow.graph[source].push(target);
        }
        Ok(())
    }
    while let Some(i) = work.pop_front() {
        let block = &f.blocks[i];
        let mut active = flow.entries[i].clone().unwrap();
        if polls[i] {
            unwind(&mut flow, &mut work, f, blocks, i, 0, &active)?;
        }
        for (at, inst) in block.instructions.iter().enumerate() {
            if may_unwind(inst, f) {
                unwind(&mut flow, &mut work, f, blocks, i, at, &active)?;
            }
            if let Instruction::Allocate {
                storage: Storage::Stack(name),
                ..
            }
            | Instruction::Closure {
                storage: Storage::Stack(name),
                ..
            } = inst
                && !active
                    .iter()
                    .any(|r| f.regions[r.region].stack_object.as_ref() == Some(name))
            {
                return Err(format!("stack object {name} has no active root region"));
            }
            match inst {
                Instruction::Enter(name, _) => {
                    let index = find_region(f, name)?;
                    if active.iter().any(|r| r.region == index) {
                        return Err(format!("region {name} is already active"));
                    }
                    if let Some(object) = &f.regions[index].stack_object
                        && active
                            .iter()
                            .any(|r| f.regions[r.region].stack_object.as_ref() == Some(object))
                    {
                        return Err(format!("stack object {object} is already registered"));
                    }
                    let outer = active.last().map(|r| f.regions[r.region].name.as_str());
                    if outer != f.regions[index].outer.as_deref() {
                        return Err(format!("region {name} has the wrong outer region"));
                    }
                    active.push(ActiveRegion {
                        region: index,
                        cleanup: false,
                    });
                }
                Instruction::Leave(name) => {
                    if active.last().map(|r| f.regions[r.region].name.as_str()) != Some(name) {
                        return Err(format!("leave {name} is not innermost"));
                    }
                    active.pop();
                }
                Instruction::Runtime {
                    operation, region, ..
                } => {
                    let handler = active
                        .iter()
                        .rev()
                        .find(|r| !r.cleanup && f.regions[r.region].kind.has_handler())
                        .map(|r| f.regions[r.region].name.as_str());
                    if (operation.descriptor().safepoint || region.is_some())
                        && region.as_deref() != handler
                    {
                        return Err("runtime region is not the current innermost handler".into());
                    }
                }
                Instruction::Numeric { region, .. }
                | Instruction::Call { region, .. }
                | Instruction::CallSpread { region, .. } => {
                    let handler = active
                        .iter()
                        .rev()
                        .find(|r| !r.cleanup && f.regions[r.region].kind.has_handler())
                        .map(|r| f.regions[r.region].name.as_str());
                    if region.as_deref() != handler {
                        return Err("call region is not the current innermost handler".into());
                    }
                }
                _ => (),
            }
        }
        match &block.terminator {
            Terminator::Return(_) | Terminator::ReturnMv(_) | Terminator::TailCall(..)
                if !active.is_empty() =>
            {
                return Err("return or tail-call with active regions".into());
            }
            Terminator::ContinueUnwind(name) => {
                if !active
                    .last()
                    .is_some_and(|r| r.cleanup && f.regions[r.region].name == *name)
                {
                    return Err("continue-unwind requires the innermost running cleanup".into());
                }
                unwind(
                    &mut flow,
                    &mut work,
                    f,
                    blocks,
                    i,
                    block.instructions.len(),
                    &active,
                )?;
            }
            Terminator::Error { .. } | Terminator::Throw { .. } | Terminator::ExitTo { .. } => {
                unwind(
                    &mut flow,
                    &mut work,
                    f,
                    blocks,
                    i,
                    block.instructions.len(),
                    &active,
                )?;
            }
            _ => (),
        }
        for &target in &normal[i] {
            enter_block(&mut flow, &mut work, f, target, &active)?;
        }
    }
    Ok(flow)
}

fn function(f: &Function, module: &Module, functions: &HashSet<&str>) -> Result<Flow> {
    if f.receive > ARGUMENT_LIMIT {
        return Err("receive declaration exceeds argument limit".into());
    }
    if f.captures > crate::packet::schema::MAX_BYTES as usize / 16 {
        return Err("capture declaration exceeds request limit".into());
    }
    if f.blocks.is_empty() {
        return Err("function has no entry block".into());
    }
    let mut types = Types {
        vars: HashMap::new(),
    };
    for (name, ty) in &f.vars {
        if name.is_empty() || types.vars.insert(name, *ty).is_some() {
            return Err(format!("duplicate or empty variable {name}"));
        }
    }
    if let Some(rest) = &f.rest {
        types.expect(&rest.variable, Type::Obj)?;
        if rest.first > ARGUMENT_LIMIT || rest.stack_capacity > ARGUMENT_LIMIT {
            return Err("rest start exceeds argument limit".into());
        }
    }
    let mut blocks = HashMap::new();
    for (i, block) in f.blocks.iter().enumerate() {
        if block.name.is_empty() || blocks.insert(block.name.as_str(), i).is_some() {
            return Err("duplicate or empty block name".into());
        }
    }
    let mut regions = HashSet::new();
    let mut landings = HashMap::new();
    let mut objects = HashSet::new();
    let mut frame_bytes = f
        .regions
        .len()
        .checked_mul(size_of::<kiln_rt::context::DynEntry>())
        .ok_or("stack frame declaration overflow")?;
    if let Some(rest) = &f.rest {
        frame_bytes = frame_bytes
            .checked_add(
                rest.stack_capacity
                    * (kiln_rt::object::CONS_BYTES + size_of::<kiln_rt::context::DynEntry>()),
            )
            .ok_or("stack frame declaration overflow")?;
    }
    for object in &f.stack_objects {
        if object.name.is_empty() || !objects.insert(object.name.as_str()) {
            return Err("duplicate or empty stack object name".into());
        }
        let (class, count) = object.shape(&module.functions)?;
        let (bytes, _, _) = crate::lir::stack_object_layout(class, count as i64)?;
        frame_bytes = frame_bytes
            .checked_add(bytes as usize)
            .ok_or("stack frame declaration overflow")?;
    }
    if frame_bytes > i32::MAX as usize {
        return Err("stack frame declaration exceeds target address range".into());
    }
    for (i, r) in f.regions.iter().enumerate() {
        if r.name.is_empty() || r.name == "nil" || !regions.insert(r.name.as_str()) {
            return Err("duplicate or invalid region name".into());
        }
        if r.kind.has_handler() != r.landing.is_some() {
            return Err("region landing declaration does not match its kind".into());
        }
        if (r.kind == RegionKind::StackRoots) != r.stack_object.is_some() {
            return Err("stack-roots declaration needs exactly one stack object".into());
        }
        if let Some(name) = &r.stack_object {
            find_stack_object(f, name)?;
        }
        if let Some(landing) = &r.landing {
            let block = *blocks
                .get(landing.as_str())
                .ok_or("undefined landing block")?;
            if block == 0 {
                return Err("landing cannot be the function entry".into());
            }
            if landings.insert(block, i).is_some() {
                return Err("regions cannot share a landing block".into());
            }
            if !matches!(f.blocks[block].instructions.first(), Some(Instruction::Landing { region, .. }) if region == &r.name)
            {
                return Err(
                    "landing block must begin with its region's landing instruction".into(),
                );
            }
        }
        let mut ancestors = HashSet::from([i]);
        let mut outer = r.outer.as_deref();
        while let Some(name) = outer {
            let index = find_region(f, name)?;
            if !ancestors.insert(index) {
                return Err("cyclic region declarations".into());
            }
            outer = f.regions[index].outer.as_deref();
        }
    }
    let mut expanded_stack_words = 0usize;
    for (i, block) in f.blocks.iter().enumerate() {
        for (at, inst) in block.instructions.iter().enumerate() {
            instruction(inst, &types, f, module, functions)?;
            let stack_work = match inst {
                Instruction::Enter(name, _) => f.regions[find_region(f, name)?]
                    .stack_object
                    .as_ref()
                    .map(|o| (o, 7)),
                Instruction::Allocate {
                    storage: Storage::Stack(name),
                    ..
                } => Some((name, 3)),
                Instruction::Closure {
                    storage: Storage::Stack(name),
                    fields,
                    ..
                } => Some((name, 2 + 2 * fields.as_ref().map_or(0, Vec::len))),
                _ => None,
            };
            if let Some((object, extra)) = stack_work {
                let (class, count) = find_stack_object(f, object)?.shape(&module.functions)?;
                let (bytes, _, _) = crate::lir::stack_object_layout(class, count as i64)?;
                expanded_stack_words = expanded_stack_words
                    .checked_add(bytes as usize / 8 + extra)
                    .ok_or("stack initialization expansion overflow")?;
                if expanded_stack_words
                    > (crate::packet::schema::MAX_EXPANDED_BYTES
                        / crate::packet::schema::EXPANSION_RECORD_BYTES)
                        as usize
                {
                    return Err("stack initialization exceeds expansion budget".into());
                }
            }
            if let Instruction::Landing { region, .. } = inst
                && (at != 0 || landings.get(&i) != Some(&find_region(f, region)?))
            {
                return Err("landing outside its declared block".into());
            }
        }
        terminator(&block.terminator, &types, f)?;
    }
    let normal = f
        .blocks
        .iter()
        .map(|block| {
            successors(&block.terminator)
                .iter()
                .map(|name| {
                    let target = blocks
                        .get(name)
                        .copied()
                        .ok_or_else(|| format!("undefined block {name}"))?;
                    if landings.contains_key(&target) {
                        return Err("ordinary control flow cannot enter a landing block".into());
                    }
                    Ok(target)
                })
                .collect::<Result<Vec<_>>>()
        })
        .collect::<Result<Vec<_>>>()?;

    // Adding a loop poll can introduce an exceptional edge to a previously
    // unreachable landing. Iterate until the poll set covers that graph too.
    let mut polls = vec![false; f.blocks.len()];
    let regions = loop {
        let flow = region_flow(f, &normal, &blocks, &polls)?;
        let selected = loop_polls(&flow.graph);
        let mut changed = false;
        for (old, new) in polls.iter_mut().zip(selected) {
            if new && !*old {
                *old = true;
                changed = true;
            }
        }
        if !changed {
            break flow;
        }
    };
    let mut entries = vec![None; f.blocks.len()];
    let mut initial = State::default();
    if let Some(rest) = &f.rest {
        initial.initialized.insert(rest.variable.clone());
    }
    entries[0] = Some(initial);
    let mut work = VecDeque::from([0]);
    let mut queued = vec![false; f.blocks.len()];
    queued[0] = true;
    fn propagate(
        entries: &mut [Option<State>],
        work: &mut VecDeque<usize>,
        queued: &mut [bool],
        target: usize,
        state: &State,
    ) {
        let changed = if let Some(entry) = &mut entries[target] {
            entry.merge(state)
        } else {
            entries[target] = Some(state.clone());
            true
        };
        if changed && !queued[target] {
            work.push_back(target);
            queued[target] = true;
        }
    }
    while let Some(i) = work.pop_front() {
        queued[i] = false;
        let mut state = entries[i].clone().unwrap();
        if polls[i] {
            state.view = None;
        }
        for at in 0..=f.blocks[i].instructions.len() {
            for edge in regions.unwinds[i].iter().filter(|edge| edge.at == at) {
                let mut exceptional = state.clone();
                exceptional.view = None;
                propagate(
                    &mut entries,
                    &mut work,
                    &mut queued,
                    edge.target,
                    &exceptional,
                );
            }
            if let Some(inst) = f.blocks[i].instructions.get(at) {
                state.step(inst, f);
            }
        }
        for &target in &normal[i] {
            propagate(&mut entries, &mut work, &mut queued, target, &state);
        }
    }
    for (i, block) in f.blocks.iter().enumerate() {
        let Some(mut state) = entries[i].take() else {
            continue;
        };
        if polls[i] {
            state.view = None;
        }
        let check = (|| {
            for inst in &block.instructions {
                state.check_instruction(inst)?;
                state.step(inst, f);
            }
            state.check_terminator(&block.terminator)
        })();
        check.map_err(|error| format!("block {}: {error}", block.name))?;
    }
    Ok(Flow {
        polls,
        entries: regions.entries,
    })
}
