use super::*;

fn list(s: &Sexp) -> Result<&[Sexp]> {
    match s {
        Sexp::List(xs) => Ok(xs),
        _ => Err(format!("LIR: expected list, got {s}")),
    }
}
fn symbol(s: &Sexp) -> Result<String> {
    match s {
        Sexp::Sym(x) => Ok(x.clone()),
        _ => Err(format!("LIR: expected name, got {s}")),
    }
}
fn text(s: &Sexp) -> Result<String> {
    match s {
        Sexp::Str(x) => Ok(x.clone()),
        _ => Err(format!("LIR: expected string, got {s}")),
    }
}
fn integer(s: &Sexp) -> Result<i64> {
    match s {
        Sexp::Int(x) => Ok(*x),
        _ => Err(format!("LIR: expected integer, got {s}")),
    }
}
fn index(s: &Sexp) -> Result<usize> {
    usize::try_from(integer(s)?).map_err(|_| "LIR: negative index or count".into())
}
fn form(s: &Sexp) -> Result<(&str, &[Sexp])> {
    let xs = list(s)?;
    match xs.split_first() {
        Some((Sexp::Sym(name), args)) => Ok((name, args)),
        _ => Err("LIR: expected operation name".into()),
    }
}
fn arity(name: &str, xs: &[Sexp], count: usize) -> Result<()> {
    if xs.len() == count {
        Ok(())
    } else {
        Err(format!(
            "LIR {name}: expected {count} operands, got {}",
            xs.len()
        ))
    }
}
fn names(xs: &Sexp) -> Result<Vec<String>> {
    list(xs)?.iter().map(symbol).collect()
}

pub(super) fn module(program: &Sexp) -> Result<Module> {
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
    for x in xs {
        let (name, args) = form(x)?;
        match name {
            "init" => {
                arity(name, args, 1)?;
                if init {
                    return Err("LIR: duplicate init declaration".into());
                }
                module.init = text(&args[0])?;
                init = true;
            }
            "literals" => {
                arity(name, args, 1)?;
                if literals {
                    return Err("LIR: duplicate literals declaration".into());
                }
                module.literals = index(&args[0])?;
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
                let kind = crate::lir::builtins::Kind::parse(&symbol(&args[0])?)?;
                let image = match symbol(&args[1])?.as_str() {
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

fn function(xs: &[Sexp]) -> Result<Function> {
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
    for x in xs {
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
                    index(&values[0])?
                } else {
                    0
                };
                function.rest = Some(RestArguments {
                    variable: symbol(&args[0])?,
                    first: index(&args[1])?,
                    stack_capacity,
                });
            }
            "receive" => {
                arity(name, args, 1)?;
                if receive {
                    return Err("LIR: duplicate receive declaration".into());
                }
                function.receive = index(&args[0])?;
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
                for entry in list(&args[4])? {
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
                        variable: symbol(&entry[0])?,
                        name: constant_value(&entry[1])?,
                        cell,
                    });
                }
                function.debug = Some(DebugMetadata {
                    name: constant_value(&args[0])?,
                    file: constant_value(&args[1])?,
                    start: u32::try_from(integer(&args[2])?)
                        .map_err(|_| "LIR: invalid debug start")?,
                    end: u32::try_from(integer(&args[3])?).map_err(|_| "LIR: invalid debug end")?,
                    variables,
                });
            }
            "captures" => {
                arity(name, args, 1)?;
                if captures {
                    return Err("LIR: duplicate captures declaration".into());
                }
                function.captures = index(&args[0])?;
                captures = true;
            }
            "vars" => {
                if vars {
                    return Err("LIR: duplicate vars declaration".into());
                }
                for var in args {
                    let var = list(var)?;
                    arity("variable", var, 2)?;
                    let ty = match symbol(&var[1])?.as_str() {
                        "obj" => Type::Obj,
                        "word" => Type::Word,
                        "f64" => Type::F64,
                        "mv" => Type::Mv,
                        ty => return Err(format!("LIR: unknown representation {ty}")),
                    };
                    function.vars.push((symbol(&var[0])?, ty));
                }
                vars = true;
            }
            "region" => {
                if !(3..=4).contains(&args.len()) {
                    return Err("LIR: region needs name, kind, outer and optional landing".into());
                }
                let kind = match symbol(&args[1])?.as_str() {
                    "catch" => RegionKind::Catch,
                    "unwind-protect" => RegionKind::UnwindProtect,
                    "exit-point" => RegionKind::ExitPoint,
                    "bind" => RegionKind::Bind,
                    "progv" => RegionKind::Progv,
                    "stack-roots" => RegionKind::StackRoots,
                    name => return Err(format!("LIR: unknown region kind {name}")),
                };
                let outer = symbol(&args[2])?;
                let fourth = args.get(3).map(symbol).transpose()?;
                function.regions.push(Region {
                    name: symbol(&args[0])?,
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
                let kind = if matches!(&args[1], Sexp::Sym(name) if name == "cons") {
                    StackKind::Cons
                } else {
                    let (name, args) = form(&args[1])?;
                    if name != "closure" {
                        return Err("LIR: unknown stack object kind".into());
                    }
                    arity(name, args, 1)?;
                    StackKind::Closure(text(&args[0])?)
                };
                function.stack_objects.push(StackObject {
                    name: symbol(&args[0])?,
                    kind,
                });
            }
            "block" => function.blocks.push(block(args)?),
            _ => return Err(format!("LIR: unknown function declaration {name}")),
        }
    }
    Ok(function)
}

fn block(xs: &[Sexp]) -> Result<Block> {
    let (name, xs) = xs.split_first().ok_or("LIR: missing block name")?;
    let mut instructions = Vec::new();
    let mut terminator = None;
    for x in xs {
        if terminator.is_some() {
            return Err("LIR: instruction after terminator".into());
        }
        let (name, args) = form(x)?;
        let term = match name {
            "jump" => {
                arity(name, args, 1)?;
                Some(Terminator::Jump(symbol(&args[0])?))
            }
            "branch" => {
                arity(name, args, 3)?;
                Some(Terminator::Branch(
                    symbol(&args[0])?,
                    symbol(&args[1])?,
                    symbol(&args[2])?,
                ))
            }
            "switch" => {
                let [value, default, cases @ ..] = args else {
                    return Err("LIR: switch needs value and default".into());
                };
                let cases = cases
                    .iter()
                    .map(|case| {
                        let case = list(case)?;
                        arity("switch case", case, 2)?;
                        Ok((integer(&case[0])?, symbol(&case[1])?))
                    })
                    .collect::<Result<_>>()?;
                Some(Terminator::Switch(symbol(value)?, symbol(default)?, cases))
            }
            "return" => {
                arity(name, args, 1)?;
                Some(Terminator::Return(names(&args[0])?))
            }
            "return-mv" => {
                arity(name, args, 1)?;
                Some(Terminator::ReturnMv(symbol(&args[0])?))
            }
            "tail-call" => {
                arity(name, args, 2)?;
                Some(Terminator::TailCall(symbol(&args[0])?, names(&args[1])?))
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
                        u32::try_from(integer(&range[0])?).map_err(|_| "LIR: invalid location")?,
                        u32::try_from(integer(&range[1])?).map_err(|_| "LIR: invalid location")?,
                    ))
                } else {
                    None
                };
                Some(if name == "fatal-error" {
                    Terminator::FatalError {
                        code: symbol(&args[0])?,
                        value: symbol(&args[1])?,
                        loc: location,
                    }
                } else {
                    Terminator::Error {
                        code: integer(&args[0])?,
                        value: symbol(&args[1])?,
                        loc: location,
                    }
                })
            }
            "throw" | "exit-to" => {
                arity(name, args, 2)?;
                Some(if name == "throw" {
                    Terminator::Throw {
                        tag: symbol(&args[0])?,
                        view: symbol(&args[1])?,
                    }
                } else {
                    Terminator::ExitTo {
                        token: symbol(&args[0])?,
                        view: symbol(&args[1])?,
                    }
                })
            }
            "continue-unwind" => {
                arity(name, args, 1)?;
                Some(Terminator::ContinueUnwind(symbol(&args[0])?))
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
            "alloc-symbol" => {
                arity(name, args, 2)?;
                Instruction::AllocateSymbol {
                    result: symbol(&args[0])?,
                    name: symbol(&args[1])?,
                }
            }
            "alloc-undefined-function" => {
                arity(name, args, 3)?;
                let setf = match symbol(&args[2])?.as_str() {
                    "ordinary" => false,
                    "setf" => true,
                    _ => return Err("LIR: invalid undefined function kind".into()),
                };
                Instruction::AllocateUndefined {
                    result: symbol(&args[0])?,
                    symbol: symbol(&args[1])?,
                    setf,
                }
            }
            "alloc-sequence" => {
                arity(name, args, 4)?;
                let kind = match symbol(&args[1])?.as_str() {
                    "simple-vector" => SequenceKind::Vector,
                    "string" => SequenceKind::String,
                    _ => return Err("LIR: unsupported sequence kind".into()),
                };
                Instruction::AllocateSequence {
                    result: symbol(&args[0])?,
                    kind,
                    length: symbol(&args[2])?,
                    initial: symbol(&args[3])?,
                }
            }
            "vector" => {
                arity(name, args, 2)?;
                Instruction::Vector {
                    result: symbol(&args[0])?,
                    elements: names(&args[1])?,
                }
            }
            "alloc-structure" => {
                arity(name, args, 4)?;
                Instruction::AllocateStructure {
                    result: symbol(&args[0])?,
                    layout: symbol(&args[1])?,
                    count: symbol(&args[2])?,
                    initial: symbol(&args[3])?,
                }
            }
            "alloc-instance" => {
                arity(name, args, 7)?;
                let funcallable = match symbol(&args[1])?.as_str() {
                    "standard-instance" => false,
                    "funcallable-instance" => true,
                    _ => return Err("LIR: unsupported instance kind".into()),
                };
                Instruction::AllocateInstance {
                    result: symbol(&args[0])?,
                    funcallable,
                    class: symbol(&args[2])?,
                    count: symbol(&args[3])?,
                    stamp: symbol(&args[4])?,
                    slots: symbol(&args[5])?,
                    initial: symbol(&args[6])?,
                }
            }
            "set" => {
                arity(name, args, 2)?;
                Instruction::Set(symbol(&args[0])?, expression(&args[1])?)
            }
            "cell-set" => {
                arity(name, args, 2)?;
                Instruction::CellSet(index(&args[0])?, symbol(&args[1])?)
            }
            "field-set" => {
                arity(name, args, 3)?;
                Instruction::FieldSet(field(&args[0])?, symbol(&args[1])?, symbol(&args[2])?)
            }
            "special-set" => {
                arity(name, args, 2)?;
                Instruction::SpecialSet(symbol(&args[0])?, symbol(&args[1])?)
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
                for option in &args[required..] {
                    let (name, args) = form(option)?;
                    match name {
                        "loc" => {
                            arity(name, args, 2)?;
                            if loc.is_some() {
                                return Err("LIR: duplicate call location".into());
                            }
                            let start = u32::try_from(integer(&args[0])?)
                                .map_err(|_| "LIR: invalid location")?;
                            let end = u32::try_from(integer(&args[1])?)
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
                            let name = symbol(&args[0])?;
                            region = (name != "nil").then_some(name);
                            region_seen = true;
                        }
                        _ => return Err(format!("LIR: unknown call option {name}")),
                    }
                }
                if name == "runtime" {
                    Instruction::Runtime {
                        result: symbol(&args[0])?,
                        operation: RuntimeOperation::parse(&symbol(&args[1])?)
                            .ok_or("LIR: unknown runtime operation")?,
                        args: names(&args[2])?,
                        loc,
                        region,
                    }
                } else if name == "numeric" {
                    Instruction::Numeric {
                        result: symbol(&args[0])?,
                        operation: NumericOperation::parse(&symbol(&args[1])?)
                            .ok_or("LIR: unknown numeric operation")?,
                        args: names(&args[2])?,
                        loc,
                        region,
                    }
                } else if name == "call-spread" {
                    Instruction::CallSpread {
                        result: symbol(&args[0])?,
                        callee: symbol(&args[1])?,
                        fixed: names(&args[2])?,
                        list: symbol(&args[3])?,
                        loc,
                        region,
                    }
                } else {
                    let known = name == "call-known";
                    Instruction::Call {
                        entry: if known { Some(text(&args[1])?) } else { None },
                        result: symbol(&args[0])?,
                        callee: symbol(&args[if known { 2 } else { 1 }])?,
                        args: names(&args[if known { 3 } else { 2 }])?,
                        loc,
                        region,
                    }
                }
            }
            "values-from-list" => {
                arity(name, args, 2)?;
                Instruction::ValuesFromList {
                    result: symbol(&args[0])?,
                    list: symbol(&args[1])?,
                }
            }
            "mv-push" => {
                arity(name, args, 3)?;
                Instruction::MvPush {
                    result: symbol(&args[0])?,
                    view: symbol(&args[1])?,
                    acc: symbol(&args[2])?,
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
                    result: symbol(&args[0])?,
                    overflow: symbol(&args[1])?,
                    left: symbol(&args[2])?,
                    right: symbol(&args[3])?,
                }
            }
            "mv-move" => {
                arity(name, args, 2)?;
                Instruction::MvMove {
                    result: symbol(&args[0])?,
                    view: symbol(&args[1])?,
                }
            }
            "mv-save" | "mv-restore" => {
                arity(name, args, 2)?;
                if name == "mv-save" {
                    Instruction::MvSave {
                        result: symbol(&args[0])?,
                        view: symbol(&args[1])?,
                    }
                } else {
                    Instruction::MvRestore {
                        result: symbol(&args[0])?,
                        saved: symbol(&args[1])?,
                    }
                }
            }
            "enter" => {
                arity(name, args, 2)?;
                Instruction::Enter(symbol(&args[0])?, names(&args[1])?)
            }
            "leave" => {
                arity(name, args, 1)?;
                Instruction::Leave(symbol(&args[0])?)
            }
            "landing" => {
                if !(1..=2).contains(&args.len()) {
                    return Err("LIR: landing needs region and optional result".into());
                }
                Instruction::Landing {
                    region: symbol(&args[0])?,
                    result: args.get(1).map(symbol).transpose()?,
                }
            }
            "values" => {
                arity(name, args, 2)?;
                Instruction::Values(symbol(&args[0])?, names(&args[1])?)
            }
            "make-closure" | "alloc-closure" => {
                arity(name, args, if name == "make-closure" { 4 } else { 3 })?;
                Instruction::Closure {
                    result: symbol(&args[0])?,
                    entry: text(&args[1])?,
                    fields: args.get(3).map(names).transpose()?,
                    storage: storage(&args[2])?,
                }
            }
            "capture-set" => {
                arity(name, args, 4)?;
                Instruction::CaptureSet {
                    closure: symbol(&args[0])?,
                    entry: text(&args[1])?,
                    index: index(&args[2])?,
                    value: symbol(&args[3])?,
                }
            }
            "alloc" => {
                arity(name, args, 4)?;
                let kind = match symbol(&args[1])?.as_str() {
                    "cons" => Allocation::Cons,
                    "double-float" => Allocation::Double,
                    "complex" => Allocation::Complex,
                    "standard-instance" => Allocation::Instance,
                    name => return Err(format!("LIR: unsupported allocation kind {name}")),
                };
                Instruction::Allocate {
                    result: symbol(&args[0])?,
                    kind,
                    fields: names(&args[3])?,
                    storage: storage(&args[2])?,
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
        instructions,
        terminator: terminator.ok_or("LIR: unterminated block")?,
    })
}

fn storage(value: &Sexp) -> Result<Storage> {
    if matches!(value, Sexp::Sym(name) if name == "heap") {
        return Ok(Storage::Heap);
    }
    let (name, args) = form(value)?;
    if name != "stack" {
        return Err("LIR: unknown storage kind".into());
    }
    arity(name, args, 1)?;
    Ok(Storage::Stack(symbol(&args[0])?))
}

fn expression(x: &Sexp) -> Result<Expression> {
    if let Sexp::Sym(var) = x {
        return Ok(Expression::Copy(var.clone()));
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
            let n = integer(&args[0])?;
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
            Expression::Argument(index(&args[0])?)
        }
        "cell-ref" => {
            arity(name, args, 1)?;
            Expression::CellRef(index(&args[0])?)
        }
        "constant" => {
            arity(name, args, 1)?;
            Expression::ConstantRef(index(&args[0])?)
        }
        "literal" => {
            arity(name, args, 1)?;
            Expression::Literal(index(&args[0])?)
        }
        "function" => {
            arity(name, args, 1)?;
            Expression::Function(text(&args[0])?)
        }
        "capture-ref" => {
            arity(name, args, 1)?;
            Expression::Capture(index(&args[0])?)
        }
        "field-ref" => {
            arity(name, args, 2)?;
            Expression::Field(field(&args[0])?, symbol(&args[1])?)
        }
        "special-ref" => {
            arity(name, args, 1)?;
            Expression::Special(symbol(&args[0])?)
        }
        "test" => {
            arity(name, args, 2)?;
            Expression::Test(class(&args[0])?, symbol(&args[1])?)
        }
        "select" => {
            arity(name, args, 3)?;
            Expression::Select(symbol(&args[0])?, symbol(&args[1])?, symbol(&args[2])?)
        }
        "mv-count" => {
            arity(name, args, 1)?;
            Expression::MvCount(symbol(&args[0])?)
        }
        "mv-ref" => {
            arity(name, args, 2)?;
            Expression::MvRef(symbol(&args[0])?, index(&args[1])?)
        }
        _ => return Err(format!("LIR: unknown expression {name}")),
    })
}

fn field(x: &Sexp) -> Result<Field> {
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
fn class(x: &Sexp) -> Result<Class> {
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
        "standard-instance" => Class::Instance,
        "funcallable-instance" => Class::Funcallable,
        "complex" => Class::Complex,
        "structure-instance" => Class::Structure,
        name => return Err(format!("LIR: unknown representation class {name}")),
    })
}

fn constant_value(x: &Sexp) -> Result<ConstantValue> {
    match expression(x)? {
        Expression::ConstantRef(i) => Ok(ConstantValue::Ref(i)),
        Expression::Literal(i) => Ok(ConstantValue::Literal(i)),
        Expression::Constant(c) if !matches!(c, Constant::Word(_) | Constant::F64(_)) => {
            Ok(ConstantValue::Immediate(c))
        }
        _ => Err("LIR: expected object constant or constant reference".into()),
    }
}
fn constant_object(x: &Sexp) -> Result<ConstantObject> {
    let (name, args) = form(x)?;
    Ok(match name {
        "string" => {
            if let [Sexp::Str(s)] = args {
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
                package: text(&args[0])?,
                name: text(&args[1])?,
            }
        }
        "uninterned" => {
            arity(name, args, 2)?;
            ConstantObject::Uninterned {
                name: text(&args[0])?,
                id: index(&args[1])?,
            }
        }
        "function" => {
            arity(name, args, 1)?;
            ConstantObject::Function(text(&args[0])?)
        }
        "bignum" => {
            arity(name, args, 1)?;
            ConstantObject::Bignum(
                text(&args[0])?
                    .parse()
                    .map_err(|_| "LIR: invalid bignum decimal string")?,
            )
        }
        "vector" => ConstantObject::Vector(args.iter().map(constant_value).collect::<Result<_>>()?),
        "double-bits" => {
            arity(name, args, 1)?;
            ConstantObject::Double(integer(&args[0])? as u64)
        }
        "cons" | "mutable-cons" | "ratio" | "complex" => {
            arity(name, args, 2)?;
            let a = constant_value(&args[0])?;
            let b = constant_value(&args[1])?;
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
