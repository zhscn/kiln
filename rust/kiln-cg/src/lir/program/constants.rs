use super::*;
use crate::kir::{Data, DataContents, Expr, Word};
use kiln_rt::object::*;
use num_bigint::BigInt;
use num_integer::Integer;
use std::collections::{HashMap, HashSet, VecDeque};

pub(super) fn verify(module: &Module) -> Result<()> {
    if module.cells.len() > crate::packet::schema::MAX_BYTES as usize / 8 {
        return Err("LIR: cell table exceeds request limit".into());
    }
    for value in &module.cells {
        validate_value(module, value)?;
    }
    let mut words = module.cells.len();
    let mut identities = std::collections::HashMap::new();
    for node in &module.constants {
        let values: Vec<&ConstantValue> = match node {
            ConstantObject::Cons(a, b)
            | ConstantObject::MutableCons(a, b)
            | ConstantObject::Ratio(a, b)
            | ConstantObject::Complex(a, b) => vec![a, b],
            ConstantObject::Vector(xs) => xs.iter().collect(),
            _ => vec![],
        };
        for value in values {
            validate_value(module, value)?;
        }

        match node {
            ConstantObject::Uninterned { name, id } => {
                if identities.insert(*id, name).is_some_and(|old| old != name) {
                    return Err("LIR: conflicting uninterned identity".into());
                }
            }
            ConstantObject::Symbol { package, .. } if package.is_empty() => {
                return Err("LIR: empty symbol package".into());
            }
            ConstantObject::Function(entry) => {
                if !module
                    .functions
                    .iter()
                    .any(|f| &f.name == entry && f.captures == 0)
                {
                    return Err("LIR: constant function requires a zero-capture entry".into());
                }
            }
            ConstantObject::Bignum(n)
                if *n >= BigInt::from(FIXNUM_MIN) && *n <= BigInt::from(FIXNUM_MAX) =>
            {
                return Err("LIR: bignum fits fixnum representation".into());
            }
            ConstantObject::Ratio(a, b) => {
                let a = integer(module, a).ok_or("LIR: ratio numerator must be an integer")?;
                let b = integer(module, b).ok_or("LIR: ratio denominator must be an integer")?;
                if b <= BigInt::from(1) || a.gcd(&b) != BigInt::from(1) {
                    return Err("LIR: ratio must be normalized".into());
                }
            }
            ConstantObject::Complex(a, b) => {
                let a = number_class(module, a).ok_or("LIR: invalid complex real part")?;
                let b_class =
                    number_class(module, b).ok_or("LIR: invalid complex imaginary part")?;
                if a != b_class || (a == 0 && integer(module, b) == Some(BigInt::from(0))) {
                    return Err("LIR: complex parts must have matching numeric types and nonzero rational imaginary part".into());
                }
            }
            _ => (),
        }
        let size = match node {
            ConstantObject::Symbol { package, name } => {
                20 + package.len().div_ceil(2) + name.len().div_ceil(2)
            }
            ConstantObject::Uninterned { name, .. } => 20 + name.len().div_ceil(2),
            ConstantObject::Function(_) => 0,
            ConstantObject::Bignum(n) => 1 + n.to_signed_bytes_le().len().div_ceil(8),
            ConstantObject::String(xs) => {
                if xs.iter().any(|n| *n >= 0x110000) {
                    return Err("LIR: invalid string character".into());
                }
                1 + xs.len().div_ceil(2)
            }
            ConstantObject::Vector(xs) => 1 + xs.len(),
            ConstantObject::Double(_) => 2,
            _ => 3,
        };
        words = words
            .checked_add(size)
            .ok_or("LIR: constant graph size overflow")?;
        if words > crate::packet::schema::MAX_BYTES as usize / 8 {
            return Err("LIR: constant graph exceeds request limit".into());
        }
    }
    Ok(())
}

pub(super) fn lower(
    module: &Module,
    result: &mut kir::Module,
    imports: &mut HashSet<String>,
) -> Result<Vec<Expr>> {
    // Encoding every byte makes module names injective even when they contain punctuation.
    let identity: String = module
        .name
        .as_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let mut labels: Vec<String> = (0..module.constants.len())
        .map(|i| format!("_kiln_lir_constant_{identity}_{i}"))
        .collect();
    for (i, node) in module.constants.iter().enumerate() {
        match node {
            ConstantObject::Symbol { package, name } => {
                labels[i] = if package == "COMMON-LISP" && (name == "NIL" || name == "T") {
                    let label = if name == "NIL" { "kiln_nil" } else { "kiln_t" };
                    imports.insert(label.into());
                    label.into()
                } else {
                    let label = format!("kiln_sym_{}", mangle(&format!("{package}:{name}")));
                    symbol(result, imports, &label, name, Some(package));
                    label
                };
            }
            ConstantObject::Uninterned { name, id } => {
                let label = format!("_kiln_lir_uninterned_{identity}_{id}");
                symbol(result, imports, &label, name, None);
                labels[i] = label;
            }
            ConstantObject::Function(entry) => labels[i] = format!("_kiln_lir_object_{entry}"),
            _ => (),
        }
    }
    let canonical = canonical_nodes(module);
    let original_labels = labels.clone();
    for (i, target) in canonical.iter().enumerate() {
        labels[i] = original_labels[*target].clone();
    }
    let tag = |i: usize| if matches!(module.constants[i], ConstantObject::Cons(..) | ConstantObject::MutableCons(..)) { TAG_CONS } else { TAG_GENERAL } as i64;
    let objects: Vec<_> = labels
        .iter()
        .enumerate()
        .map(|(i, label)| Expr::Addr(label.clone(), tag(i)))
        .collect();
    let mut value = |v: &ConstantValue| word(v, &objects, imports);
    for (i, node) in module.constants.iter().enumerate() {
        if canonical[i] != i {
            continue;
        }
        let header = |kind: u64, n: usize| Word::Int((kind | ((n as u64) << LENGTH_SHIFT)) as i64);
        let words = match node {
            ConstantObject::Symbol { .. }
            | ConstantObject::Uninterned { .. }
            | ConstantObject::Function(_) => continue,
            ConstantObject::Bignum(n) => crate::lir::static_objects::integer_words(n),
            ConstantObject::String(xs) => {
                let mut words = vec![header(KIND_STRING, xs.len())];
                words.extend(xs.chunks(2).map(|p| {
                    Word::Int((u64::from(p[0]) | (u64::from(*p.get(1).unwrap_or(&0)) << 32)) as i64)
                }));
                words
            }
            ConstantObject::Vector(xs) => {
                let mut words = vec![header(KIND_SIMPLE_VECTOR, xs.len())];
                words.extend(xs.iter().map(&mut value));
                words
            }
            ConstantObject::Double(bits) => {
                vec![header(KIND_DOUBLE, 0), Word::Int(*bits as i64)]
            }
            ConstantObject::Cons(a, b)
            | ConstantObject::MutableCons(a, b)
            | ConstantObject::Ratio(a, b)
            | ConstantObject::Complex(a, b) => {
                let kind = match node {
                    ConstantObject::Cons(..) | ConstantObject::MutableCons(..) => KIND_CONS,
                    ConstantObject::Ratio(..) => KIND_RATIO,
                    _ => KIND_COMPLEX,
                };
                vec![header(kind, 0), value(a), value(b)]
            }
        };
        let fields: Vec<&ConstantValue> = match node {
            ConstantObject::Vector(xs) => xs.iter().collect(),
            ConstantObject::Cons(a, b)
            | ConstantObject::MutableCons(a, b)
            | ConstantObject::Ratio(a, b)
            | ConstantObject::Complex(a, b) => vec![a, b],
            _ => vec![],
        };
        for (field, value) in fields.into_iter().enumerate() {
            if let ConstantValue::Literal(index) = value {
                result
                    .literal_patches
                    .push((labels[i].clone(), (field + 1) as u32, *index));
            }
        }
        let object_fields = match node {
            ConstantObject::Vector(xs) => xs.len(),
            ConstantObject::Cons(..)
            | ConstantObject::MutableCons(..)
            | ConstantObject::Ratio(..)
            | ConstantObject::Complex(..) => 2,
            _ => 0,
        };
        result
            .roots
            .extend((1..=object_fields).map(|word| (labels[i].clone(), word as u32)));
        result.data.push(Data {
            name: labels[i].clone(),
            contents: DataContents::Words(words),
        });
    }
    if !module.cells.is_empty() {
        let label = cell_label(module);
        let words = module.cells.iter().map(&mut value).collect();
        for (i, cell) in module.cells.iter().enumerate() {
            if let ConstantValue::Literal(index) = cell {
                result
                    .literal_patches
                    .push((label.clone(), i as u32, *index));
            }
        }
        crate::lir::cells::declare(result, label, words)?;
    }
    Ok(labels
        .into_iter()
        .enumerate()
        .map(|(i, label)| Expr::Addr(label, tag(i)))
        .collect())
}

fn integer(module: &Module, value: &ConstantValue) -> Option<BigInt> {
    match value {
        ConstantValue::Immediate(Constant::Fixnum(n)) => Some(BigInt::from(*n)),
        ConstantValue::Ref(i) => match module.constants.get(*i)? {
            ConstantObject::Bignum(n) => Some(n.clone()),
            _ => None,
        },
        _ => None,
    }
}
fn number_class(module: &Module, value: &ConstantValue) -> Option<u8> {
    if integer(module, value).is_some() {
        return Some(0);
    }
    match value {
        ConstantValue::Immediate(Constant::Single(_)) => Some(1),
        ConstantValue::Ref(i) => match module.constants.get(*i)? {
            ConstantObject::Ratio(..) => Some(0),
            ConstantObject::Double(_) => Some(2),
            _ => None,
        },
        _ => None,
    }
}

fn mangle(text: &str) -> String {
    text.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_string()
            } else {
                format!("_{:X}_", c as u32)
            }
        })
        .collect()
}
fn string(result: &mut kir::Module, label: String, text: &str) -> String {
    if !result.shared.contains(&label) {
        let codes: Vec<u32> = text.chars().map(u32::from).collect();
        let mut words = vec![Word::Int(
            (KIND_STRING | ((codes.len() as u64) << LENGTH_SHIFT)) as i64,
        )];
        words.extend(codes.chunks(2).map(|p| {
            Word::Int((u64::from(p[0]) | (u64::from(*p.get(1).unwrap_or(&0)) << 32)) as i64)
        }));
        result.data.push(Data {
            name: label.clone(),
            contents: DataContents::Words(words),
        });
        result.shared.insert(label.clone());
    }
    label
}
pub(super) fn symbol(
    result: &mut kir::Module,
    imports: &mut HashSet<String>,
    label: &str,
    name: &str,
    package: Option<&str>,
) {
    if result.shared.contains(label) {
        return;
    }
    let suffix = label.strip_prefix("kiln_sym_").unwrap_or(label);
    let name_label = string(result, format!("kiln_name_{suffix}"), name);
    let addr = |s: String| Word::DataAddr(s, TAG_GENERAL as i64);
    imports.insert("kiln_nil".into());
    let package_word = package.map_or_else(
        || addr("kiln_nil".into()),
        |p| addr(string(result, format!("kiln_pkg_{}", mangle(p)), p)),
    );
    let mut undefs = Vec::new();
    for (prefix, entry) in [
        ("kiln_undef_", "kiln_undefined_function"),
        ("kiln_undef_setf_", "kiln_undefined_setf_function"),
    ] {
        let undef = format!("{prefix}{suffix}");
        imports.insert(entry.into());
        result.data.push(Data {
            name: undef.clone(),
            contents: DataContents::Words(vec![
                Word::Int((KIND_FUNCTION | (1 << LENGTH_SHIFT)) as i64),
                Word::CodeAddr(entry.into()),
                addr(label.into()),
            ]),
        });
        result.shared.insert(undef.clone());
        undefs.push(undef);
    }
    let mut words = vec![Word::Int(0); size_of::<SymbolObj>() / 8];
    words[core::mem::offset_of!(SymbolObj, header) / 8] = Word::Int(KIND_SYMBOL as i64);
    for (offset, value) in [
        (core::mem::offset_of!(SymbolObj, name), addr(name_label)),
        (core::mem::offset_of!(SymbolObj, package), package_word),
        (
            core::mem::offset_of!(SymbolObj, function),
            addr(undefs[0].clone()),
        ),
        (
            core::mem::offset_of!(SymbolObj, value),
            if package == Some("KEYWORD") {
                addr(label.into())
            } else {
                Word::Int(UNBOUND as i64)
            },
        ),
        (
            core::mem::offset_of!(SymbolObj, plist),
            addr("kiln_nil".into()),
        ),
        (
            core::mem::offset_of!(SymbolObj, setf_function),
            addr(undefs[1].clone()),
        ),
    ] {
        words[offset / 8] = value;
    }
    result
        .roots
        .extend((1..words.len()).map(|i| (label.into(), i as u32)));
    result.data.push(Data {
        name: label.into(),
        contents: DataContents::Words(words),
    });
    result.shared.insert(label.into());
}

fn canonical_nodes(module: &Module) -> Vec<usize> {
    let mut canonical: Vec<usize> = (0..module.constants.len()).collect();
    let mut strings = HashMap::new();
    let mut pending = vec![0; canonical.len()];
    let mut users = vec![Vec::new(); canonical.len()];
    let mut ready = VecDeque::new();
    for (i, node) in module.constants.iter().enumerate() {
        if let ConstantObject::String(codes) = node {
            canonical[i] = *strings.entry(codes).or_insert(i);
        }
        if let ConstantObject::Cons(a, b) = node {
            for value in [a, b] {
                if let ConstantValue::Ref(child) = value
                    && matches!(module.constants[*child], ConstantObject::Cons(..))
                {
                    pending[i] += 1;
                    users[*child].push(i);
                }
            }
            if pending[i] == 0 {
                ready.push_back(i);
            }
        }
    }
    let mut conses = HashMap::new();
    while let Some(i) = ready.pop_front() {
        let ConstantObject::Cons(a, b) = &module.constants[i] else {
            unreachable!()
        };
        let key = |value: &ConstantValue| match value {
            ConstantValue::Ref(child) => ConstantValue::Ref(canonical[*child]),
            other => other.clone(),
        };
        canonical[i] = *conses.entry((key(a), key(b))).or_insert(i);
        for user in &users[i] {
            pending[*user] -= 1;
            if pending[*user] == 0 {
                ready.push_back(*user);
            }
        }
    }
    // Cycles and objects depending on cycles retain their declared identities.
    canonical
}

pub(super) fn cell_label(module: &Module) -> String {
    let identity: String = module
        .name
        .as_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    format!("_kiln_lir_cells_{identity}")
}
pub(super) fn validate_value(module: &Module, value: &ConstantValue) -> Result<()> {
    match value {
        ConstantValue::Literal(i) if *i >= module.literals => {
            Err("LIR: literal reference out of range".into())
        }
        ConstantValue::Ref(i) if *i >= module.constants.len() => {
            Err("LIR: constant reference out of range".into())
        }
        ConstantValue::Immediate(Constant::Fixnum(n)) if !(FIXNUM_MIN..=FIXNUM_MAX).contains(n) => {
            Err("LIR: fixnum constant out of range".into())
        }
        ConstantValue::Immediate(Constant::Character(n)) if *n >= 0x110000 => {
            Err("LIR: character constant out of range".into())
        }
        ConstantValue::Immediate(Constant::Word(_) | Constant::F64(_)) => {
            Err("LIR: non-object constant in graph".into())
        }
        _ => Ok(()),
    }
}

pub(super) fn word(v: &ConstantValue, objects: &[Expr], imports: &mut HashSet<String>) -> Word {
    match v {
        ConstantValue::Literal(_) => Word::Int(0),
        ConstantValue::Ref(i) => match &objects[*i] {
            Expr::Addr(label, tag) => Word::DataAddr(label.clone(), *tag),
            _ => unreachable!("constant object address"),
        },
        ConstantValue::Immediate(c) => match c {
            Constant::Fixnum(n) => Word::Int(n << 1),
            Constant::Character(n) => Word::Int(((u64::from(*n) << 8) | CHARACTER_TAG) as i64),
            Constant::Single(n) => {
                Word::Int(((u64::from(*n) << 32) | kiln_rt::number::SINGLE_TAG) as i64)
            }
            Constant::Nil | Constant::True => {
                let name = if matches!(c, Constant::Nil) {
                    "kiln_nil"
                } else {
                    "kiln_t"
                };
                imports.insert(name.into());
                Word::DataAddr(name.into(), TAG_GENERAL as i64)
            }
            Constant::Unbound => Word::Int(UNBOUND as i64),
            Constant::UnboundSlot => Word::Int(UNBOUND_SLOT as i64),
            _ => unreachable!("verified object constant"),
        },
    }
}
