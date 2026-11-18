use super::*;
use crate::kir::{Data, DataContents, Expr, Word};
use kiln_rt::object::*;
use std::collections::HashSet;

pub(super) fn check_budget(module: &Module) -> Result<()> {
    let mut words = 0usize;
    for debug in module.functions.iter().filter_map(|f| f.debug.as_ref()) {
        words = debug
            .variables
            .len()
            .checked_mul(7)
            .and_then(|count| count.checked_add(7))
            .and_then(|count| words.checked_add(count))
            .ok_or("LIR: debug expansion overflow")?;
        if words > crate::packet::schema::MAX_BYTES as usize / 8 {
            return Err("LIR: debug data exceeds request limit".into());
        }
    }
    Ok(())
}

pub(super) fn verify_function(
    module: &Module,
    function: &Function,
    variable_type: impl Fn(&str) -> Option<Type>,
) -> Result<Vec<Type>> {
    let Some(debug) = &function.debug else {
        return Ok(Vec::new());
    };
    if debug.start > debug.end {
        return Err("LIR: reversed debug source range".into());
    }
    constants::validate_value(module, &debug.name)?;
    constants::validate_value(module, &debug.file)?;
    let mut seen = HashSet::with_capacity(debug.variables.len());
    let mut types = Vec::with_capacity(debug.variables.len());
    for variable in &debug.variables {
        let ty = variable_type(&variable.variable).ok_or("LIR: debug variable is not declared")?;
        if !matches!(ty, Type::Obj | Type::F64) || (variable.cell && ty != Type::Obj) {
            return Err("LIR: invalid debug variable representation".into());
        }
        if !seen.insert(&variable.variable) {
            return Err("LIR: duplicate debug variable".into());
        }
        constants::validate_value(module, &variable.name)?;
        types.push(ty);
    }
    Ok(types)
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
    verified: &Verified<'_>,
    objects: &[Expr],
    result: &mut kir::Module,
    imports: &mut HashSet<String>,
) {
    for (function, flow) in verified.module.functions.iter().zip(&verified.flow) {
        let Some(debug) = &function.debug else {
            continue;
        };
        let label = label(function);
        let names = format!("{label}_names");
        let mut variables = Vec::new();
        for (i, (variable, &ty)) in debug.variables.iter().zip(&flow.debug_types).enumerate() {
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
