use super::*;
use crate::packet::{Packet, Record};

#[derive(Clone, Copy, Debug)]
pub(super) enum Node<'a> {
    Integer(i64),
    Symbol(&'a str),
    String(&'a str),
    List(Nodes<'a>),
}

#[derive(Clone, Copy)]
pub(super) enum Nodes<'a> {
    Text(&'a [Sexp<'a>]),
    Packet(Packet<'a>, usize, usize),
}

impl std::fmt::Debug for Nodes<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_list().entries(self.iter()).finish()
    }
}

impl<'a> Node<'a> {
    pub(super) fn text(value: &'a Sexp<'a>) -> Self {
        match value {
            Sexp::Int(n) => Self::Integer(*n),
            Sexp::Sym(s) => Self::Symbol(s),
            Sexp::Str(s) => Self::String(s),
            Sexp::List(xs) => Self::List(Nodes::Text(xs)),
        }
    }

    pub(super) fn packet(packet: Packet<'a>, id: usize) -> Self {
        match packet.record(id) {
            Record::Integer(n) => Self::Integer(n),
            Record::Symbol(s) => Self::Symbol(s),
            Record::String(s) => Self::String(s),
            Record::List { start, len } => Self::List(Nodes::Packet(packet, start, len)),
        }
    }
}

impl<'a> Nodes<'a> {
    fn len(self) -> usize {
        match self {
            Self::Text(xs) => xs.len(),
            Self::Packet(_, _, len) => len,
        }
    }

    fn at(self, index: usize) -> Node<'a> {
        assert!(index < self.len());
        match self {
            Self::Text(xs) => Node::text(&xs[index]),
            Self::Packet(packet, start, _) => Node::packet(packet, packet.child(start + index)),
        }
    }

    fn get(self, index: usize) -> Option<Node<'a>> {
        (index < self.len()).then(|| self.at(index))
    }

    fn tail(self, count: usize) -> Self {
        assert!(count <= self.len());
        match self {
            Self::Text(xs) => Self::Text(&xs[count..]),
            Self::Packet(packet, start, len) => Self::Packet(packet, start + count, len - count),
        }
    }

    fn split_first(self) -> Option<(Node<'a>, Self)> {
        self.get(0).map(|head| (head, self.tail(1)))
    }

    fn iter(self) -> impl ExactSizeIterator<Item = Node<'a>> {
        (0..self.len()).map(move |index| self.at(index))
    }
}

fn list(node: Node<'_>) -> Result<Nodes<'_>> {
    match node {
        Node::List(xs) => Ok(xs),
        _ => Err(format!("LIR: expected list, got {node:?}")),
    }
}

fn symbol(node: Node<'_>) -> Result<String> {
    match node {
        Node::Symbol(name) => Ok(name.into()),
        _ => Err(format!("LIR: expected name, got {node:?}")),
    }
}

fn text(node: Node<'_>) -> Result<String> {
    match node {
        Node::String(value) => Ok(value.into()),
        _ => Err(format!("LIR: expected string, got {node:?}")),
    }
}

fn integer(node: Node<'_>) -> Result<i64> {
    match node {
        Node::Integer(value) => Ok(value),
        _ => Err(format!("LIR: expected integer, got {node:?}")),
    }
}

fn index(node: Node<'_>) -> Result<usize> {
    usize::try_from(integer(node)?).map_err(|_| "LIR: negative index or count".into())
}

fn form(node: Node<'_>) -> Result<(&str, Nodes<'_>)> {
    match list(node)?.split_first() {
        Some((Node::Symbol(name), args)) => Ok((name, args)),
        _ => Err("LIR: expected operation name".into()),
    }
}

fn arity(name: &str, xs: Nodes, count: usize) -> Result<()> {
    if xs.len() == count {
        Ok(())
    } else {
        Err(format!(
            "LIR {name}: expected {count} operands, got {}",
            xs.len()
        ))
    }
}
fn names(xs: Node) -> Result<Vec<String>> {
    list(xs)?.iter().map(symbol).collect()
}

pub(super) fn module(program: Node) -> Result<Module> {
    let (name, xs) = form(program)?;
    if name != "lir-module" {
        return Err("LIR: expected lir-module".into());
    }
    let (name, xs) = xs.split_first().ok_or("LIR: missing module name")?;
    let mut module = Module {
        name: text(name)?,
        init: String::new(),
        literals: 0,
        builtins: vec![],
        constants: vec![],
        cells: vec![],
        functions: vec![],
    };
    let mut init = false;
    let mut literals = false;
    let mut constants = false;
    let mut cells = false;
    for x in xs.iter() {
        let (name, args) = form(x)?;
        match name {
            "init" => {
                arity(name, args, 1)?;
                if init {
                    return Err("LIR: duplicate init declaration".into());
                }
                module.init = text(args.at(0))?;
                init = true;
            }
            "literals" => {
                arity(name, args, 1)?;
                if literals {
                    return Err("LIR: duplicate literals declaration".into());
                }
                module.literals = index(args.at(0))?;
                literals = true;
            }
            "cells" => {
                if cells {
                    return Err("LIR: duplicate cells declaration".into());
                }
                module.cells = args.iter().map(constant_value).collect::<Result<_>>()?;
                cells = true;
            }
            "constants" => {
                if constants {
                    return Err("LIR: duplicate constants declaration".into());
                }
                module.constants = args.iter().map(constant_object).collect::<Result<_>>()?;
                constants = true;
            }
            "builtin" => {
                arity(name, args, 2)?;
                let kind = crate::lir::builtins::Kind::parse(&symbol(args.at(0))?)?;
                let image = match symbol(args.at(1))?.as_str() {
                    "file" => false,
                    "image" => true,
                    _ => return Err("LIR: invalid builtin scope".into()),
                };
                module.builtins.push((kind, image));
            }
            "function" => module.functions.push(function(args)?),
            _ => return Err(format!("LIR: unknown module declaration {name}")),
        }
    }
    if !init {
        return Err("LIR: missing init declaration".into());
    }
    Ok(module)
}

fn function(xs: Nodes) -> Result<Function> {
    let (name, xs) = xs.split_first().ok_or("LIR: missing function name")?;
    let mut function = Function {
        name: text(name)?,
        receive: 0,
        rest: None,
        captures: 0,
        debug: None,
        vars: vec![],
        regions: vec![],
        stack_objects: vec![],
        blocks: vec![],
    };
    let mut receive = false;
    let mut captures = false;
    let mut vars = false;
    for x in xs.iter() {
        let (name, args) = form(x)?;
        match name {
            "rest" => {
                if !(2..=3).contains(&args.len()) {
                    return Err(
                        "LIR: rest needs variable, start and optional stack capacity".into(),
                    );
                }
                if function.rest.is_some() {
                    return Err("LIR: duplicate rest declaration".into());
                }
                let stack_capacity = if let Some(storage) = args.get(2) {
                    let (kind, values) = form(storage)?;
                    if kind != "stack" {
                        return Err("LIR: invalid rest storage".into());
                    }
                    arity(kind, values, 1)?;
                    index(values.at(0))?
                } else {
                    0
                };
                function.rest = Some(RestArguments {
                    variable: symbol(args.at(0))?,
                    first: index(args.at(1))?,
                    stack_capacity,
                });
            }
            "receive" => {
                arity(name, args, 1)?;
                if receive {
                    return Err("LIR: duplicate receive declaration".into());
                }
                function.receive = index(args.at(0))?;
                receive = true;
            }
            "debug" => {
                if function.debug.is_some() {
                    return Err("LIR: duplicate debug declaration".into());
                }
                if args.len() != 5 {
                    return Err("LIR: debug needs name, file, source range and variables".into());
                }
                let mut variables = Vec::new();
                for entry in list(args.at(4))?.iter() {
                    let entry = list(entry)?;
                    if !(2..=3).contains(&entry.len()) {
                        return Err(
                            "LIR: debug variable needs variable, name and optional cell".into()
                        );
                    }
                    let cell = if let Some(option) = entry.get(2) {
                        if symbol(option)? != "cell" {
                            return Err("LIR: invalid debug variable option".into());
                        }
                        true
                    } else {
                        false
                    };
                    variables.push(DebugVariable {
                        variable: symbol(entry.at(0))?,
                        name: constant_value(entry.at(1))?,
                        cell,
                    });
                }
                function.debug = Some(DebugMetadata {
                    name: constant_value(args.at(0))?,
                    file: constant_value(args.at(1))?,
                    start: u32::try_from(integer(args.at(2))?)
                        .map_err(|_| "LIR: invalid debug start")?,
                    end: u32::try_from(integer(args.at(3))?)
                        .map_err(|_| "LIR: invalid debug end")?,
                    variables,
                });
            }
            "captures" => {
                arity(name, args, 1)?;
                if captures {
                    return Err("LIR: duplicate captures declaration".into());
                }
                function.captures = index(args.at(0))?;
                captures = true;
            }
            "vars" => {
                if vars {
                    return Err("LIR: duplicate vars declaration".into());
                }
                for var in args.iter() {
                    let var = list(var)?;
                    arity("variable", var, 2)?;
                    let ty = match symbol(var.at(1))?.as_str() {
                        "obj" => Type::Obj,
                        "word" => Type::Word,
                        "f32" => Type::F32,
                        "f64" => Type::F64,
                        "mv" => Type::Mv,
                        ty => return Err(format!("LIR: unknown representation {ty}")),
                    };
                    function.vars.push((symbol(var.at(0))?, ty));
                }
                vars = true;
            }
            "region" => {
                if !(3..=4).contains(&args.len()) {
                    return Err("LIR: region needs name, kind, outer and optional landing".into());
                }
                let kind = match symbol(args.at(1))?.as_str() {
                    "catch" => RegionKind::Catch,
                    "unwind-protect" => RegionKind::UnwindProtect,
                    "exit-point" => RegionKind::ExitPoint,
                    "bind" => RegionKind::Bind,
                    "progv" => RegionKind::Progv,
                    "stack-roots" => RegionKind::StackRoots,
                    name => return Err(format!("LIR: unknown region kind {name}")),
                };
                let outer = symbol(args.at(2))?;
                let fourth = args.get(3).map(symbol).transpose()?;
                function.regions.push(Region {
                    name: symbol(args.at(0))?,
                    kind,
                    outer: (outer != "nil").then_some(outer),
                    landing: if kind == RegionKind::StackRoots {
                        None
                    } else {
                        fourth.clone()
                    },
                    stack_object: if kind == RegionKind::StackRoots {
                        fourth
                    } else {
                        None
                    },
                });
            }
            "stack-object" => {
                arity(name, args, 2)?;
                let kind = if matches!(args.at(1), Node::Symbol(name) if name == "cons") {
                    StackKind::Cons
                } else {
                    let (name, args) = form(args.at(1))?;
                    if name != "closure" {
                        return Err("LIR: unknown stack object kind".into());
                    }
                    arity(name, args, 1)?;
                    StackKind::Closure(text(args.at(0))?)
                };
                function.stack_objects.push(StackObject {
                    name: symbol(args.at(0))?,
                    kind,
                });
            }
            "block" => function.blocks.push(block(args)?),
            _ => return Err(format!("LIR: unknown function declaration {name}")),
        }
    }
    Ok(function)
}

fn block(xs: Nodes) -> Result<Block> {
    let (name, xs) = xs.split_first().ok_or("LIR: missing block name")?;
    let mut instructions = Vec::new();
    let mut terminator = None;
    let mut cold = false;
    for (position, x) in xs.iter().enumerate() {
        if terminator.is_some() {
            return Err("LIR: instruction after terminator".into());
        }
        let (name, args) = form(x)?;
        if position == 0 && name == "cold" {
            arity(name, args, 0)?;
            cold = true;
            continue;
        }
        let term = match name {
            "jump" => {
                arity(name, args, 1)?;
                Some(Terminator::Jump(symbol(args.at(0))?))
            }
            "branch" => {
                arity(name, args, 3)?;
                Some(Terminator::Branch(
                    symbol(args.at(0))?,
                    symbol(args.at(1))?,
                    symbol(args.at(2))?,
                ))
            }
            "poll-branch" => {
                arity(name, args, 2)?;
                Some(Terminator::PollBranch(symbol(args.at(0))?, symbol(args.at(1))?))
            }
            "switch" => {
                if args.len() < 2 {
                    return Err("LIR: switch needs value and default".into());
                };
                let cases = args
                    .tail(2)
                    .iter()
                    .map(|case| {
                        let case = list(case)?;
                        arity("switch case", case, 2)?;
                        Ok((integer(case.at(0))?, symbol(case.at(1))?))
                    })
                    .collect::<Result<_>>()?;
                Some(Terminator::Switch(
                    symbol(args.at(0))?,
                    symbol(args.at(1))?,
                    cases,
                ))
            }
            "return" => {
                arity(name, args, 1)?;
                Some(Terminator::Return(names(args.at(0))?))
            }
            "return-mv" => {
                arity(name, args, 1)?;
                Some(Terminator::ReturnMv(symbol(args.at(0))?))
            }
            "tail-call" => {
                arity(name, args, 2)?;
                Some(Terminator::TailCall(
                    symbol(args.at(0))?,
                    names(args.at(1))?,
                ))
            }
            "error" | "fatal-error" => {
                if !(2..=3).contains(&args.len()) {
                    return Err("LIR: error needs code, object and optional location".into());
                }
                let location = if let Some(x) = args.get(2) {
                    let (tag, range) = form(x)?;
                    if tag != "loc" {
                        return Err("LIR: expected error location".into());
                    }
                    arity(tag, range, 2)?;
                    Some((
                        u32::try_from(integer(range.at(0))?)
                            .map_err(|_| "LIR: invalid location")?,
                        u32::try_from(integer(range.at(1))?)
                            .map_err(|_| "LIR: invalid location")?,
                    ))
                } else {
                    None
                };
                Some(if name == "fatal-error" {
                    Terminator::FatalError {
                        code: symbol(args.at(0))?,
                        value: symbol(args.at(1))?,
                        loc: location,
                    }
                } else {
                    Terminator::Error {
                        code: integer(args.at(0))?,
                        value: symbol(args.at(1))?,
                        loc: location,
                    }
                })
            }
            "throw" | "exit-to" => {
                arity(name, args, 2)?;
                Some(if name == "throw" {
                    Terminator::Throw {
                        tag: symbol(args.at(0))?,
                        view: symbol(args.at(1))?,
                    }
                } else {
                    Terminator::ExitTo {
                        token: symbol(args.at(0))?,
                        view: symbol(args.at(1))?,
                    }
                })
            }
            "continue-unwind" => {
                arity(name, args, 1)?;
                Some(Terminator::ContinueUnwind(symbol(args.at(0))?))
            }
            "trap" => {
                arity(name, args, 0)?;
                Some(Terminator::Trap)
            }
            _ => None,
        };
        if term.is_some() {
            terminator = term;
            continue;
        }
        if let Some(operation) = StoreOperation::parse(name) {
            instructions.push(Instruction::Store(
                operation,
                args.iter().map(symbol).collect::<Result<_>>()?,
            ));
            continue;
        }
        instructions.push(match name {
            "alloc-rack" => {
                arity(name, args, 3)?;
                Instruction::AllocateRack {
                    result: symbol(args.at(0))?,
                    class: symbol(args.at(1))?,
                    count: symbol(args.at(2))?,
                }
            }
            "alloc-funcallable" => {
                arity(name, args, 2)?;
                Instruction::AllocateFuncallable {
                    result: symbol(args.at(0))?,
                    rack: symbol(args.at(1))?,
                }
            }
            "alloc-symbol" => {
                arity(name, args, 2)?;
                Instruction::AllocateSymbol {
                    result: symbol(args.at(0))?,
                    name: symbol(args.at(1))?,
                }
            }
            "alloc-undefined-function" => {
                arity(name, args, 3)?;
                let setf = match symbol(args.at(2))?.as_str() {
                    "ordinary" => false,
                    "setf" => true,
                    _ => return Err("LIR: invalid undefined function kind".into()),
                };
                Instruction::AllocateUndefined {
                    result: symbol(args.at(0))?,
                    symbol: symbol(args.at(1))?,
                    setf,
                }
            }
            "alloc-sequence" => {
                arity(name, args, 4)?;
                let kind = match symbol(args.at(1))?.as_str() {
                    "simple-vector" => SequenceKind::Vector,
                    "string" => SequenceKind::String,
                    "double-storage" => SequenceKind::DoubleStorage,
                    _ => return Err("LIR: unsupported sequence kind".into()),
                };
                Instruction::AllocateSequence {
                    result: symbol(args.at(0))?,
                    kind,
                    length: symbol(args.at(2))?,
                    initial: symbol(args.at(3))?,
                }
            }
            "vector" => {
                arity(name, args, 2)?;
                Instruction::Vector {
                    result: symbol(args.at(0))?,
                    elements: names(args.at(1))?,
                }
            }
            "alloc-structure" => {
                arity(name, args, 4)?;
                Instruction::AllocateStructure {
                    result: symbol(args.at(0))?,
                    layout: symbol(args.at(1))?,
                    count: symbol(args.at(2))?,
                    initial: symbol(args.at(3))?,
                }
            }
            "alloc-instance" => {
                arity(name, args, 7)?;
                let funcallable = match symbol(args.at(1))?.as_str() {
                    "standard-instance" => false,
                    "funcallable-instance" => true,
                    _ => return Err("LIR: unsupported instance kind".into()),
                };
                Instruction::AllocateInstance {
                    result: symbol(args.at(0))?,
                    funcallable,
                    class: symbol(args.at(2))?,
                    count: symbol(args.at(3))?,
                    stamp: symbol(args.at(4))?,
                    slots: symbol(args.at(5))?,
                    initial: symbol(args.at(6))?,
                }
            }
            "set" => {
                arity(name, args, 2)?;
                Instruction::Set(symbol(args.at(0))?, expression(args.at(1))?)
            }
            "cell-set" => {
                arity(name, args, 2)?;
                Instruction::CellSet(index(args.at(0))?, symbol(args.at(1))?)
            }
            "field-set" => {
                arity(name, args, 3)?;
                Instruction::FieldSet(field(args.at(0))?, symbol(args.at(1))?, symbol(args.at(2))?)
            }
            "special-set" => {
                arity(name, args, 2)?;
                Instruction::SpecialSet(symbol(args.at(0))?, symbol(args.at(1))?)
            }
            "call" | "call-known" | "call-spread" | "numeric" | "runtime" => {
                let required = if matches!(name, "call-spread" | "call-known") {
                    4
                } else {
                    3
                };
                if args.len() < required {
                    return Err(
                        "LIR: call needs result, callee, arguments and optional location".into(),
                    );
                }
                let mut loc = None;
                let mut region = None;
                let mut region_seen = false;
                for option in args.tail(required).iter() {
                    let (name, args) = form(option)?;
                    match name {
                        "loc" => {
                            arity(name, args, 2)?;
                            if loc.is_some() {
                                return Err("LIR: duplicate call location".into());
                            }
                            let start = u32::try_from(integer(args.at(0))?)
                                .map_err(|_| "LIR: invalid location")?;
                            let end = u32::try_from(integer(args.at(1))?)
                                .map_err(|_| "LIR: invalid location")?;
                            if end < start {
                                return Err("LIR: reversed location".into());
                            }
                            loc = Some((start, end));
                        }
                        "region" => {
                            arity(name, args, 1)?;
                            if region_seen {
                                return Err("LIR: duplicate call region".into());
                            }
                            let name = symbol(args.at(0))?;
                            region = (name != "nil").then_some(name);
                            region_seen = true;
                        }
                        _ => return Err(format!("LIR: unknown call option {name}")),
                    }
                }
                if name == "runtime" {
                    Instruction::Runtime {
                        result: symbol(args.at(0))?,
                        operation: RuntimeOperation::parse(&symbol(args.at(1))?)
                            .ok_or("LIR: unknown runtime operation")?,
                        args: names(args.at(2))?,
                        loc,
                        region,
                    }
                } else if name == "numeric" {
                    Instruction::Numeric {
                        result: symbol(args.at(0))?,
                        operation: NumericOperation::parse(&symbol(args.at(1))?)
                            .ok_or("LIR: unknown numeric operation")?,
                        args: names(args.at(2))?,
                        loc,
                        region,
                    }
                } else if name == "call-spread" {
                    Instruction::CallSpread {
                        result: symbol(args.at(0))?,
                        callee: symbol(args.at(1))?,
                        fixed: names(args.at(2))?,
                        list: symbol(args.at(3))?,
                        loc,
                        region,
                    }
                } else {
                    let known = name == "call-known";
                    Instruction::Call {
                        entry: if known { Some(text(args.at(1))?) } else { None },
                        result: symbol(args.at(0))?,
                        callee: symbol(args.at(if known { 2 } else { 1 }))?,
                        args: names(args.at(if known { 3 } else { 2 }))?,
                        loc,
                        region,
                    }
                }
            }
            "values-from-list" => {
                arity(name, args, 2)?;
                Instruction::ValuesFromList {
                    result: symbol(args.at(0))?,
                    list: symbol(args.at(1))?,
                }
            }
            "mv-push" => {
                arity(name, args, 3)?;
                Instruction::MvPush {
                    result: symbol(args.at(0))?,
                    view: symbol(args.at(1))?,
                    acc: symbol(args.at(2))?,
                }
            }
            "fixnum-add-ovf" | "fixnum-sub-ovf" | "fixnum-mul-ovf" => {
                arity(name, args, 4)?;
                Instruction::FixnumChecked {
                    operation: match name {
                        "fixnum-add-ovf" => FixnumArithmetic::Add,
                        "fixnum-sub-ovf" => FixnumArithmetic::Sub,
                        _ => FixnumArithmetic::Mul,
                    },
                    result: symbol(args.at(0))?,
                    overflow: symbol(args.at(1))?,
                    left: symbol(args.at(2))?,
                    right: symbol(args.at(3))?,
                }
            }
            "mv-move" => {
                arity(name, args, 2)?;
                Instruction::MvMove {
                    result: symbol(args.at(0))?,
                    view: symbol(args.at(1))?,
                }
            }
            "mv-save" | "mv-restore" => {
                arity(name, args, 2)?;
                if name == "mv-save" {
                    Instruction::MvSave {
                        result: symbol(args.at(0))?,
                        view: symbol(args.at(1))?,
                    }
                } else {
                    Instruction::MvRestore {
                        result: symbol(args.at(0))?,
                        saved: symbol(args.at(1))?,
                    }
                }
            }
            "enter" => {
                arity(name, args, 2)?;
                Instruction::Enter(symbol(args.at(0))?, names(args.at(1))?)
            }
            "leave" => {
                arity(name, args, 1)?;
                Instruction::Leave(symbol(args.at(0))?)
            }
            "landing" => {
                if !(1..=2).contains(&args.len()) {
                    return Err("LIR: landing needs region and optional result".into());
                }
                Instruction::Landing {
                    region: symbol(args.at(0))?,
                    result: args.get(1).map(symbol).transpose()?,
                }
            }
            "values" => {
                arity(name, args, 2)?;
                Instruction::Values(symbol(args.at(0))?, names(args.at(1))?)
            }
            "make-closure" | "alloc-closure" => {
                arity(name, args, if name == "make-closure" { 4 } else { 3 })?;
                Instruction::Closure {
                    result: symbol(args.at(0))?,
                    entry: text(args.at(1))?,
                    fields: args.get(3).map(names).transpose()?,
                    storage: storage(args.at(2))?,
                }
            }
            "capture-set" => {
                arity(name, args, 4)?;
                Instruction::CaptureSet {
                    closure: symbol(args.at(0))?,
                    entry: text(args.at(1))?,
                    index: index(args.at(2))?,
                    value: symbol(args.at(3))?,
                }
            }
            "alloc" => {
                arity(name, args, 4)?;
                let kind = match symbol(args.at(1))?.as_str() {
                    "cons" => Allocation::Cons,
                    "double-float" => Allocation::Double,
                    "complex" => Allocation::Complex,
                    "standard-instance" => Allocation::Instance,
                    name => return Err(format!("LIR: unsupported allocation kind {name}")),
                };
                Instruction::Allocate {
                    result: symbol(args.at(0))?,
                    kind,
                    fields: names(args.at(3))?,
                    storage: storage(args.at(2))?,
                }
            }
            "poll" => {
                arity(name, args, 0)?;
                Instruction::Poll
            }
            _ => return Err(format!("LIR: unknown instruction {name}")),
        });
    }
    Ok(Block {
        name: symbol(name)?,
        cold,
        instructions,
        terminator: terminator.ok_or("LIR: unterminated block")?,
    })
}

fn storage(value: Node) -> Result<Storage> {
    if matches!(value, Node::Symbol(name) if name == "heap") {
        return Ok(Storage::Heap);
    }
    let (name, args) = form(value)?;
    if name != "stack" {
        return Err("LIR: unknown storage kind".into());
    }
    arity(name, args, 1)?;
    Ok(Storage::Stack(symbol(args.at(0))?))
}

fn expression(x: Node) -> Result<Expression> {
    if let Node::Symbol(var) = x {
        return Ok(Expression::Copy(var.to_string()));
    }
    let (name, args) = form(x)?;
    if let Some(op) = Op::parse(name) {
        arity(name, args, op.signature().0.len())?;
        return Ok(Expression::Op(
            op,
            args.iter().map(symbol).collect::<Result<_>>()?,
        ));
    }
    let constant = match name {
        "word" | "fixnum" | "character" | "single-float" | "f64" => {
            arity(name, args, 1)?;
            let n = integer(args.at(0))?;
            Some(match name {
                "word" => Constant::Word(n),
                "fixnum" => Constant::Fixnum(n),
                "character" => {
                    Constant::Character(u32::try_from(n).map_err(|_| "LIR: invalid character")?)
                }
                "single-float" => Constant::Single(
                    u32::try_from(n).map_err(|_| "LIR: invalid single-float bits")?,
                ),
                _ => Constant::F64(n as u64),
            })
        }
        "nil" | "t" | "unbound" | "unbound-slot" => {
            arity(name, args, 0)?;
            Some(match name {
                "nil" => Constant::Nil,
                "t" => Constant::True,
                "unbound" => Constant::Unbound,
                _ => Constant::UnboundSlot,
            })
        }
        _ => None,
    };
    if let Some(c) = constant {
        return Ok(Expression::Constant(c));
    }
    Ok(match name {
        "self" => {
            arity(name, args, 0)?;
            Expression::SelfObject
        }
        "frame-pointer" => {
            arity(name, args, 0)?;
            Expression::FramePointer
        }
        "arg-count" => {
            arity(name, args, 0)?;
            Expression::ArgumentCount
        }
        "arg-ref" => {
            arity(name, args, 1)?;
            Expression::Argument(index(args.at(0))?)
        }
        "cell-ref" => {
            arity(name, args, 1)?;
            Expression::CellRef(index(args.at(0))?)
        }
        "constant" => {
            arity(name, args, 1)?;
            Expression::ConstantRef(index(args.at(0))?)
        }
        "literal" => {
            arity(name, args, 1)?;
            Expression::Literal(index(args.at(0))?)
        }
        "function" => {
            arity(name, args, 1)?;
            Expression::Function(text(args.at(0))?)
        }
        "capture-ref" => {
            arity(name, args, 1)?;
            Expression::Capture(index(args.at(0))?)
        }
        "field-ref" => {
            arity(name, args, 2)?;
            Expression::Field(field(args.at(0))?, symbol(args.at(1))?)
        }
        "special-ref" => {
            arity(name, args, 1)?;
            Expression::Special(symbol(args.at(0))?)
        }
        "test" => {
            arity(name, args, 2)?;
            Expression::Test(class(args.at(0))?, symbol(args.at(1))?)
        }
        "select" => {
            arity(name, args, 3)?;
            Expression::Select(
                symbol(args.at(0))?,
                symbol(args.at(1))?,
                symbol(args.at(2))?,
            )
        }
        "mv-count" => {
            arity(name, args, 1)?;
            Expression::MvCount(symbol(args.at(0))?)
        }
        "mv-ref" => {
            arity(name, args, 2)?;
            Expression::MvRef(symbol(args.at(0))?, index(args.at(1))?)
        }
        _ => return Err(format!("LIR: unknown expression {name}")),
    })
}

fn field(x: Node) -> Result<Field> {
    Ok(match symbol(x)?.as_str() {
        "cons.car" => Field::Car,
        "cons.cdr" => Field::Cdr,
        "symbol.name" => Field::SymbolName,
        "symbol.package" => Field::SymbolPackage,
        "symbol.function" => Field::SymbolFunction,
        "symbol.value" => Field::SymbolValue,
        "symbol.plist" => Field::SymbolPlist,
        "symbol.setf-function" => Field::SymbolSetfFunction,
        "complex.real" => Field::ComplexReal,
        "complex.imag" => Field::ComplexImag,
        name => return Err(format!("LIR: unknown field {name}")),
    })
}
fn class(x: Node) -> Result<Class> {
    Ok(match symbol(x)?.as_str() {
        "fixnum" => Class::Fixnum,
        "cons" => Class::Cons,
        "character" => Class::Character,
        "single-float" => Class::Single,
        "symbol" => Class::Symbol,
        "function" => Class::Function,
        "simple-vector" => Class::Vector,
        "string" => Class::String,
        "bignum" => Class::Bignum,
        "ratio" => Class::Ratio,
        "double-float" => Class::Double,
        "double-storage" => Class::DoubleStorage,
        "standard-instance" => Class::Instance,
        "funcallable-instance" => Class::Funcallable,
        "complex" => Class::Complex,
        "structure-instance" => Class::Structure,
        name => return Err(format!("LIR: unknown representation class {name}")),
    })
}

fn constant_value(x: Node) -> Result<ConstantValue> {
    match expression(x)? {
        Expression::ConstantRef(i) => Ok(ConstantValue::Ref(i)),
        Expression::Literal(i) => Ok(ConstantValue::Literal(i)),
        Expression::Constant(c) if !matches!(c, Constant::Word(_) | Constant::F64(_)) => {
            Ok(ConstantValue::Immediate(c))
        }
        _ => Err("LIR: expected object constant or constant reference".into()),
    }
}
fn constant_object(x: Node) -> Result<ConstantObject> {
    let (name, args) = form(x)?;
    Ok(match name {
        "string" => {
            if let (1, Some(Node::String(s))) = (args.len(), args.get(0)) {
                ConstantObject::String(s.chars().map(u32::from).collect())
            } else {
                ConstantObject::String(
                    args.iter()
                        .map(|x| {
                            let n = u32::try_from(integer(x)?)
                                .map_err(|_| "invalid string character")?;
                            if n >= 0x110000 {
                                return Err("invalid string character".into());
                            }
                            Ok(n)
                        })
                        .collect::<Result<_>>()?,
                )
            }
        }
        "symbol" => {
            arity(name, args, 2)?;
            ConstantObject::Symbol {
                package: text(args.at(0))?,
                name: text(args.at(1))?,
            }
        }
        "uninterned" => {
            arity(name, args, 2)?;
            ConstantObject::Uninterned {
                name: text(args.at(0))?,
                id: index(args.at(1))?,
            }
        }
        "function" => {
            arity(name, args, 1)?;
            ConstantObject::Function(text(args.at(0))?)
        }
        "bignum" => {
            arity(name, args, 1)?;
            ConstantObject::Bignum(
                text(args.at(0))?
                    .parse()
                    .map_err(|_| "LIR: invalid bignum decimal string")?,
            )
        }
        "vector" => ConstantObject::Vector(args.iter().map(constant_value).collect::<Result<_>>()?),
        "double-bits" => {
            arity(name, args, 1)?;
            ConstantObject::Double(integer(args.at(0))? as u64)
        }
        "cons" | "mutable-cons" | "ratio" | "complex" => {
            arity(name, args, 2)?;
            let a = constant_value(args.at(0))?;
            let b = constant_value(args.at(1))?;
            match name {
                "cons" => ConstantObject::Cons(a, b),
                "mutable-cons" => ConstantObject::MutableCons(a, b),
                "ratio" => ConstantObject::Ratio(a, b),
                _ => ConstantObject::Complex(a, b),
            }
        }
        _ => return Err(format!("LIR: unknown constant object {name}")),
    })
}
