use super::*;
use crate::kir::{Data, DataContents, Expr, Word};
use kiln_rt::object::*;
use std::collections::HashSet;

pub(super) fn verify(module: &Module) -> Result<()> {
    let mut words = 0usize;
    for function in &module.functions {
        let Some(debug) = &function.debug else {
            continue;
        };
        if debug.start > debug.end {
            return Err("LIR: reversed debug source range".into());
        }
        constants::validate_value(module, &debug.name)?;
        constants::validate_value(module, &debug.file)?;
        let mut seen = HashSet::new();
        for variable in &debug.variables {
            let ty = function
                .vars
                .iter()
                .find(|(name, _)| name == &variable.variable)
                .map(|(_, ty)| *ty)
                .ok_or("LIR: debug variable is not declared")?;
            if !matches!(ty, Type::Obj | Type::F64) || (variable.cell && ty != Type::Obj) {
                return Err("LIR: invalid debug variable representation".into());
            }
            if !seen.insert(&variable.variable) {
                return Err("LIR: duplicate debug variable".into());
            }
            constants::validate_value(module, &variable.name)?;
        }
        words = words
            .checked_add(7 + debug.variables.len() * 7)
            .ok_or("LIR: debug expansion overflow")?;
        if words > crate::packet::schema::MAX_BYTES as usize / 8 {
            return Err("LIR: debug data exceeds request limit".into());
        }
    }
    Ok(())
}

pub(super) fn label(function: &Function) -> String {
    format!("_kiln_lir_debug_{}", function.name)
}

fn object(label: String) -> Word {
    Word::DataAddr(label, TAG_GENERAL as i64)
}
fn data(
    result: &mut kir::Module,
    label: String,
    kind: u64,
    values: Vec<(Word, Option<usize>)>,
    length: usize,
) {
    let mut words = vec![Word::Int((kind | ((length as u64) << LENGTH_SHIFT)) as i64)];
    for (i, (word, literal)) in values.into_iter().enumerate() {
        words.push(word);
        result.roots.push((label.clone(), (i + 1) as u32));
        if let Some(literal) = literal {
            result
                .literal_patches
                .push((label.clone(), (i + 1) as u32, literal));
        }
    }
    result.data.push(Data {
        name: label,
        contents: DataContents::Words(words),
    });
}
fn value(
    v: &ConstantValue,
    objects: &[Expr],
    imports: &mut HashSet<String>,
) -> (Word, Option<usize>) {
    (
        constants::word(v, objects, imports),
        if let ConstantValue::Literal(i) = v {
            Some(*i)
        } else {
            None
        },
    )
}
pub(super) fn lower(
    module: &Module,
    objects: &[Expr],
    result: &mut kir::Module,
    imports: &mut HashSet<String>,
) {
    for function in &module.functions {
        let Some(debug) = &function.debug else {
            continue;
        };
        let label = label(function);
        let names = format!("{label}_names");
        let mut variables = Vec::new();
        for (i, variable) in debug.variables.iter().enumerate() {
            let ty = function
                .vars
                .iter()
                .find(|(name, _)| name == &variable.variable)
                .unwrap()
                .1;
            let mut name = value(&variable.name, objects, imports);
            if variable.cell || ty == Type::F64 {
                let keyword = if variable.cell { "CELL" } else { "DOUBLE-BITS" };
                let symbol = format!("kiln_sym_KEYWORD_3A_{}", keyword.replace('-', "_2D_"));
                imports.insert(symbol.clone());
                let tail = format!("{label}_name_{i}_tail");
                let head = format!("{label}_name_{i}");
                imports.insert("kiln_nil".into());
                data(
                    result,
                    tail.clone(),
                    KIND_CONS,
                    vec![name, (object("kiln_nil".into()), None)],
                    0,
                );
                data(
                    result,
                    head.clone(),
                    KIND_CONS,
                    vec![
                        (object(symbol), None),
                        (Word::DataAddr(tail, TAG_CONS as i64), None),
                    ],
                    0,
                );
                name = (Word::DataAddr(head, TAG_CONS as i64), None);
            }
            variables.push(name);
        }
        data(
            result,
            names.clone(),
            KIND_SIMPLE_VECTOR,
            variables,
            debug.variables.len(),
        );
        let fields = vec![
            value(&debug.name, objects, imports),
            value(&debug.file, objects, imports),
            (Word::Int(i64::from(debug.start) << 1), None),
            (Word::Int(i64::from(debug.end) << 1), None),
            (object(names), None),
        ];
        data(result, label, KIND_SIMPLE_VECTOR, fields, 5);
    }
}
