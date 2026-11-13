//! Typed, layout-independent backend input. Parsing and verification finish
//! before any target instructions or ABI temporaries are constructed.

mod constants;
mod debug;
mod lower;
mod numeric;
pub(crate) mod runtime;
pub use numeric::NumericOperation;
pub use runtime::RuntimeOperation;
mod parse;
mod verify;

use crate::{kir, sexp::Sexp};

type Result<T> = std::result::Result<T, String>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Type {
    Obj,
    Word,
    F64,
    Mv,
}

#[derive(Debug)]
pub struct Module {
    pub name: String,
    pub init: String,
    pub literals: usize,
    pub builtins: Vec<(crate::lir::builtins::Kind, bool)>,
    pub constants: Vec<ConstantObject>,
    pub cells: Vec<ConstantValue>,
    pub functions: Vec<Function>,
}

#[derive(Debug)]
pub struct Function {
    pub name: String,
    /// Incoming slots needed by the explicit argument binding program.
    pub receive: usize,
    pub rest: Option<RestArguments>,
    pub captures: usize,
    pub debug: Option<DebugMetadata>,
    pub vars: Vec<(String, Type)>,
    pub regions: Vec<Region>,
    pub stack_objects: Vec<StackObject>,
    pub blocks: Vec<Block>,
}

#[derive(Debug)]
pub struct Region {
    pub name: String,
    pub kind: RegionKind,
    pub outer: Option<String>,
    pub landing: Option<String>,
    pub stack_object: Option<String>,
}

#[derive(Clone, Debug)]
pub struct StackObject {
    pub name: String,
    pub kind: StackKind,
}

#[derive(Clone, Debug)]
pub enum StackKind {
    Cons,
    Closure(String),
}

#[derive(Clone, Debug)]
pub enum Storage {
    Heap,
    Stack(String),
}

impl StackObject {
    fn shape(&self, functions: &[Function]) -> Result<(u32, usize)> {
        match &self.kind {
            StackKind::Cons => Ok((crate::packet::schema::CLASS_CONS, 2)),
            StackKind::Closure(entry) => {
                let function = functions
                    .iter()
                    .find(|f| &f.name == entry)
                    .ok_or_else(|| format!("undefined function {entry}"))?;
                Ok((crate::packet::schema::CLASS_FUNCTION, function.captures))
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RegionKind {
    Catch,
    UnwindProtect,
    ExitPoint,
    Bind,
    Progv,
    StackRoots,
}

impl RegionKind {
    fn name(self) -> &'static str {
        match self {
            Self::Catch => "catch",
            Self::UnwindProtect => "unwind-protect",
            Self::ExitPoint => "exit-point",
            Self::Bind => "bind",
            Self::Progv => "progv",
            Self::StackRoots => "stack-roots",
        }
    }
    fn has_handler(self) -> bool {
        !matches!(self, Self::Bind | Self::Progv | Self::StackRoots)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ActiveRegion {
    region: usize,
    cleanup: bool,
}

struct Flow {
    polls: Vec<bool>,
    /// Unreachable source blocks are checked structurally and omitted from KIR.
    entries: Vec<Option<Vec<ActiveRegion>>>,
}

#[derive(Debug)]
pub struct Block {
    pub name: String,
    pub instructions: Vec<Instruction>,
    pub terminator: Terminator,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Constant {
    Word(i64),
    Fixnum(i64),
    Character(u32),
    Single(u32),
    F64(u64),
    Nil,
    True,
    Unbound,
    UnboundSlot,
}

/// These names describe object fields, never byte offsets or code addresses.
#[derive(Clone, Copy, Debug)]
pub enum Field {
    Car,
    Cdr,
    SymbolName,
    SymbolPackage,
    SymbolFunction,
    SymbolValue,
    SymbolPlist,
    SymbolSetfFunction,
    ComplexReal,
    ComplexImag,
}

impl Field {
    fn id(self) -> u32 {
        use crate::packet::schema::*;
        match self {
            Self::Car => FIELD_CONS_CAR,
            Self::Cdr => FIELD_CONS_CDR,
            Self::SymbolName => FIELD_SYMBOL_NAME,
            Self::SymbolPackage => FIELD_SYMBOL_PACKAGE,
            Self::SymbolFunction => FIELD_SYMBOL_FUNCTION,
            Self::SymbolValue => FIELD_SYMBOL_VALUE,
            Self::SymbolPlist => FIELD_SYMBOL_PLIST,
            Self::SymbolSetfFunction => FIELD_SYMBOL_SETF_FUNCTION,
            Self::ComplexReal => FIELD_COMPLEX_REAL,
            Self::ComplexImag => FIELD_COMPLEX_IMAG,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub enum Class {
    Fixnum,
    Cons,
    Character,
    Single,
    Symbol,
    Function,
    Vector,
    String,
    Bignum,
    Ratio,
    Double,
    Instance,
    Funcallable,
    Complex,
    Structure,
}

impl Class {
    fn id(self) -> u32 {
        use crate::packet::schema::*;
        match self {
            Self::Fixnum => CLASS_FIXNUM,
            Self::Cons => CLASS_CONS,
            Self::Character => CLASS_CHARACTER,
            Self::Single => CLASS_SINGLE_FLOAT,
            Self::Symbol => CLASS_SYMBOL,
            Self::Function => CLASS_FUNCTION,
            Self::Vector => CLASS_SIMPLE_VECTOR,
            Self::String => CLASS_STRING,
            Self::Bignum => CLASS_BIGNUM,
            Self::Ratio => CLASS_RATIO,
            Self::Double => CLASS_DOUBLE,
            Self::Instance => CLASS_INSTANCE,
            Self::Funcallable => CLASS_FUNCALLABLE_INSTANCE,
            Self::Complex => CLASS_COMPLEX,
            Self::Structure => CLASS_STRUCTURE_INSTANCE,
        }
    }

    fn immediate(self) -> bool {
        matches!(
            self,
            Self::Fixnum | Self::Cons | Self::Character | Self::Single
        )
    }
}

// The enum, decoder and representation signatures share one operation table.
macro_rules! operations {
    ($($variant:ident => ($name:literal, [$($input:ident),*], $output:ident)),* $(,)?) => {
        #[derive(Clone, Copy, Debug)]
        pub enum Op { $($variant),* }
        impl Op {
            pub fn descriptors() -> &'static [(&'static str, &'static [Type], Type)] {
                &[$(($name, &[$(Type::$input),*], Type::$output)),*]
            }
            fn parse(name: &str) -> Option<Self> {
                match name { $($name => Some(Self::$variant),)* _ => None }
            }
            fn signature(self) -> (&'static [Type], Type) {
                match self { $(Self::$variant => (&[$(Type::$input),*], Type::$output),)* }
            }
        }
    }
}

operations! {
    HeapNumber => ("heap-number-p", [Obj], Word),
    HashMix => ("hash-mix", [Obj, Obj], Obj),
    WordAdd => ("word-add", [Word, Word], Word),
    WordSub => ("word-sub", [Word, Word], Word),
    WordAnd => ("word-and", [Word, Word], Word),
    WordOr => ("word-or", [Word, Word], Word),
    WordXor => ("word-xor", [Word, Word], Word),
    WordEq => ("word-eq", [Word, Word], Word),
    WordLt => ("word-lt", [Word, Word], Word),
    WordMul => ("word-mul", [Word,Word], Word),
    WordDiv => ("word-quotient", [Word,Word], Word),
    WordRem => ("word-remainder", [Word,Word], Word),
    WordNot => ("word-not", [Word], Word),
    WordNe => ("word-ne", [Word,Word], Word),
    WordLe => ("word-le", [Word,Word], Word),
    WordGt => ("word-gt", [Word,Word], Word),
    WordGe => ("word-ge", [Word,Word], Word),
    WordShl => ("word-shift-left", [Word,Word], Word),
    WordSar => ("word-shift-right", [Word,Word], Word),
    WordShr => ("word-shift-right-logical", [Word,Word], Word),
    ObjNe => ("ne", [Obj,Obj], Word),
    ObjEq => ("eq", [Obj, Obj], Word),
    FixnumTag => ("fixnum-tag", [Word], Obj),
    FixnumUntag => ("fixnum-untag", [Obj], Word),
    FixnumAdd => ("fixnum-add", [Obj, Obj], Obj),
    FixnumSub => ("fixnum-sub", [Obj, Obj], Obj),
    FixnumMul => ("fixnum-mul", [Obj, Obj], Obj),
    FixnumUnsigned => ("fixnum-unsigned-bits", [Obj], Word),
    FixnumAnd => ("fixnum-logand", [Obj,Obj], Obj),
    FixnumOr => ("fixnum-logior", [Obj,Obj], Obj),
    FixnumXor => ("fixnum-logxor", [Obj,Obj], Obj),
    FixnumNot => ("fixnum-lognot", [Obj], Obj),
    FixnumDiv => ("fixnum-quotient", [Obj,Obj], Obj),
    FixnumRem => ("fixnum-remainder", [Obj,Obj], Obj),
    FixnumEq => ("fixnum-eq", [Obj,Obj], Word),
    FixnumLt => ("fixnum-lt", [Obj,Obj], Word),
    FixnumLe => ("fixnum-le", [Obj,Obj], Word),
    FixnumGt => ("fixnum-gt", [Obj,Obj], Word),
    FixnumGe => ("fixnum-ge", [Obj,Obj], Word),
    FixnumEven => ("fixnum-evenp", [Obj], Word),
    FixnumHalf => ("fixnum-half", [Obj], Obj),
    FixnumShl => ("fixnum-shift-left", [Obj,Obj], Obj),
    FixnumSar => ("fixnum-shift-right", [Obj,Obj], Obj),
    SingleTag => ("single-float-tag", [Word], Obj),
    SingleBits => ("single-float-bits", [Obj], Word),
    InvalidVectorLength => ("invalid-vector-length", [Obj], Word),
    InvalidRackLength => ("invalid-rack-length", [Obj], Word),
    CharacterTag => ("character-tag", [Word], Obj),
    CharacterUntag => ("character-untag", [Obj], Word),
    F64Add => ("f64-add", [F64, F64], F64),
    F64Sub => ("f64-sub", [F64, F64], F64),
    F64Mul => ("f64-mul", [F64, F64], F64),
    F64Div => ("f64-div", [F64, F64], F64),
    F64Bits => ("f64-bits", [F64], Word),
    F64FromBits => ("f64-from-bits", [Word], F64),
    F64Compare => ("f64-compare", [F64,F64], Word),
    UnboxDouble => ("unbox-double", [Obj], F64),
    InstanceRack => ("instance-rack", [Obj], Obj),
    InstanceClass => ("instance-class", [Obj], Obj),
    InstanceStamp => ("instance-stamp", [Obj], Obj),
    InstanceSlots => ("instance-slot-definitions", [Obj], Obj),
    InstanceSlot => ("instance-slot", [Obj, Word], Obj),
    StructureLayout => ("structure-layout", [Obj], Obj),
    StructureSlot => ("structure-slot", [Obj, Word], Obj),
    FuncallableFunction => ("funcallable-function", [Obj], Obj),
    UndefinedFunction => ("undefined-function-p", [Obj], Word),
    VectorLength => ("vector-length", [Obj], Word),
    VectorRef => ("vector-ref", [Obj, Word], Obj),
    StringRef => ("string-ref", [Obj, Word], Obj),
}

#[derive(Debug)]
pub enum Expression {
    ConstantRef(usize),
    CellRef(usize),
    Constant(Constant),
    Copy(String),
    Op(Op, Vec<String>),
    SelfObject,
    ArgumentCount,
    FramePointer,
    Argument(usize),
    Literal(usize),
    Function(String),
    Capture(usize),
    Field(Field, String),
    Special(String),
    Test(Class, String),
    Select(String, String, String),
    MvCount(String),
    MvRef(String, usize),
}

#[derive(Clone, Copy, Debug)]
pub enum FixnumArithmetic {
    Add,
    Sub,
    Mul,
}

#[derive(Debug)]
pub enum Instruction {
    FixnumChecked {
        operation: FixnumArithmetic,
        result: String,
        overflow: String,
        left: String,
        right: String,
    },
    Runtime {
        result: String,
        operation: RuntimeOperation,
        args: Vec<String>,
        loc: Option<kir::Loc>,
        region: Option<String>,
    },
    AllocateRack {
        result: String,
        class: String,
        count: String,
    },
    AllocateFuncallable {
        result: String,
        rack: String,
    },
    AllocateSymbol {
        result: String,
        name: String,
    },
    AllocateUndefined {
        result: String,
        symbol: String,
        setf: bool,
    },
    AllocateSequence {
        result: String,
        kind: SequenceKind,
        length: String,
        initial: String,
    },
    Vector {
        result: String,
        elements: Vec<String>,
    },
    Store(StoreOperation, Vec<String>),
    AllocateStructure {
        result: String,
        layout: String,
        count: String,
        initial: String,
    },
    AllocateInstance {
        result: String,
        funcallable: bool,
        class: String,
        count: String,
        stamp: String,
        slots: String,
        initial: String,
    },
    Numeric {
        result: String,
        operation: NumericOperation,
        args: Vec<String>,
        loc: Option<kir::Loc>,
        region: Option<String>,
    },
    CellSet(usize, String),
    Set(String, Expression),
    FieldSet(Field, String, String),
    SpecialSet(String, String),
    Call {
        entry: Option<String>,
        result: String,
        callee: String,
        args: Vec<String>,
        loc: Option<kir::Loc>,
        region: Option<String>,
    },
    CallSpread {
        result: String,
        callee: String,
        fixed: Vec<String>,
        list: String,
        loc: Option<kir::Loc>,
        region: Option<String>,
    },
    Values(String, Vec<String>),
    Closure {
        result: String,
        entry: String,
        fields: Option<Vec<String>>,
        storage: Storage,
    },
    CaptureSet {
        closure: String,
        entry: String,
        index: usize,
        value: String,
    },
    ValuesFromList {
        result: String,
        list: String,
    },
    MvPush {
        result: String,
        view: String,
        acc: String,
    },
    MvMove {
        result: String,
        view: String,
    },
    MvSave {
        result: String,
        view: String,
    },
    MvRestore {
        result: String,
        saved: String,
    },
    Enter(String, Vec<String>),
    Leave(String),
    Landing {
        region: String,
        result: Option<String>,
    },
    Allocate {
        result: String,
        kind: Allocation,
        fields: Vec<String>,
        storage: Storage,
    },
    Poll,
}

#[derive(Clone, Copy, Debug)]
pub enum Allocation {
    Cons,
    Double,
    Complex,
    Instance,
}

impl Allocation {
    fn class(self) -> Class {
        match self {
            Self::Cons => Class::Cons,
            Self::Double => Class::Double,
            Self::Complex => Class::Complex,
            Self::Instance => Class::Instance,
        }
    }
    fn fields(self) -> &'static [Type] {
        match self {
            Self::Cons | Self::Complex => &[Type::Obj, Type::Obj],
            Self::Double => &[Type::F64],
            Self::Instance => &[Type::Obj],
        }
    }
}

#[derive(Debug)]
pub enum Terminator {
    FatalError {
        code: String,
        value: String,
        loc: Option<kir::Loc>,
    },
    Error {
        code: i64,
        value: String,
        loc: Option<kir::Loc>,
    },
    Jump(String),
    Branch(String, String, String),
    Switch(String, String, Vec<(i64, String)>),
    Return(Vec<String>),
    ReturnMv(String),
    TailCall(String, Vec<String>),
    Throw {
        tag: String,
        view: String,
    },
    ExitTo {
        token: String,
        view: String,
    },
    ContinueUnwind(String),
    Trap,
}

/// Only the verifier can construct the capability used by the lowerer.
pub struct Verified<'a> {
    module: &'a Module,
    flow: Vec<Flow>,
}

impl Module {
    pub fn parse(program: &Sexp) -> Result<Self> {
        parse::module(program)
    }
    pub fn verify(&self) -> Result<Verified<'_>> {
        verify::module(self)
    }
}

impl Verified<'_> {
    pub fn lower(&self) -> Result<kir::Module> {
        lower::module(self)
    }
}

pub fn compile(program: &Sexp) -> Result<kir::Module> {
    let module = Module::parse(program)?;
    module.verify()?.lower()
}

/// References may point forward or form cycles. Immutable string and cons
/// descriptions may share storage when their contents match.
#[derive(Debug)]
pub enum ConstantObject {
    Symbol { package: String, name: String },
    Uninterned { name: String, id: usize },
    Function(String),
    Bignum(num_bigint::BigInt),
    String(Vec<u32>),
    Cons(ConstantValue, ConstantValue),
    MutableCons(ConstantValue, ConstantValue),
    Vector(Vec<ConstantValue>),
    Double(u64),
    Ratio(ConstantValue, ConstantValue),
    Complex(ConstantValue, ConstantValue),
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ConstantValue {
    Literal(usize),
    Ref(usize),
    Immediate(Constant),
}

#[derive(Debug)]
pub struct DebugMetadata {
    pub name: ConstantValue,
    pub file: ConstantValue,
    pub start: u32,
    pub end: u32,
    pub variables: Vec<DebugVariable>,
}
#[derive(Debug)]
pub struct DebugVariable {
    pub variable: String,
    pub name: ConstantValue,
    pub cell: bool,
}

#[derive(Debug)]
pub struct RestArguments {
    pub variable: String,
    pub first: usize,
    pub stack_capacity: usize,
}

#[derive(Clone, Copy, Debug)]
pub enum SequenceKind {
    Vector,
    String,
}
impl SequenceKind {
    fn class(self) -> u32 {
        match self {
            Self::Vector => crate::packet::schema::CLASS_SIMPLE_VECTOR,
            Self::String => crate::packet::schema::CLASS_STRING,
        }
    }
}

macro_rules! stores {
    ($( $variant:ident => ($name:literal, [$($ty:ident),*]), )*) => {
        #[derive(Clone,Copy,Debug)]
        pub enum StoreOperation { $( $variant, )* }
        impl StoreOperation {
            fn parse(name:&str) -> Option<Self> { match name { $( $name => Some(Self::$variant), )* _=>None } }
            fn signature(self) -> &'static [Type] {match self { $(Self::$variant => &[$(Type::$ty),*],)*}}
            pub fn descriptors() -> &'static [(&'static str, &'static [Type])] {
                &[$(($name, &[$(Type::$ty),*]),)*]
            }
        }
    }
}
stores! {
    Vector => ("vector-set", [Obj,Word,Obj]),
    String => ("string-set", [Obj,Word,Obj]),
    InstanceRack => ("instance-rack-set", [Obj,Obj]),
    InstanceStamp => ("instance-stamp-set", [Obj,Obj]),
    InstanceSlots => ("instance-slot-definitions-set", [Obj,Obj]),
    InstanceSlot => ("instance-slot-set", [Obj,Word,Obj]),
    StructureSlot => ("structure-slot-set", [Obj,Word,Obj]),
    FuncallableFunction => ("funcallable-function-set", [Obj,Obj]),
}
