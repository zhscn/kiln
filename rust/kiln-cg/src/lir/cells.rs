//! Static object slots and image literal tables.
use super::*;
use crate::kir::{Data, DataContents, Module, Word};

pub const LITERALS: &str = "kiln_literals";

pub fn offset(index: usize) -> Result<i32, String> {
    let bytes = index
        .checked_mul(size_of::<u64>())
        .ok_or("object slot index out of range")?;
    if bytes >= crate::packet::schema::MAX_BYTES as usize {
        return Err("object slot index out of range".into());
    }
    i32::try_from(bytes).map_err(|_| "object slot index out of range".into())
}
pub fn load(table: String, index: usize) -> Result<Expr, String> {
    Ok(Expr::Load(Box::new(Expr::Addr(table, 0)), offset(index)?))
}
pub fn store(table: String, index: usize, value: Expr) -> Result<Stmt, String> {
    Ok(Stmt::Store(Expr::Addr(table, 0), offset(index)?, value))
}
pub fn declare(module: &mut Module, name: String, words: Vec<Word>) -> Result<(), String> {
    if !words.is_empty() {
        offset(words.len() - 1)?;
    }
    module
        .roots
        .extend((0..words.len()).map(|i| (name.clone(), i as u32)));
    module.data.push(Data {
        name,
        contents: DataContents::Words(words),
    });
    Ok(())
}
pub fn literals(module: &mut Module, count: usize) -> Result<(), String> {
    if count != 0 {
        offset(count - 1)?;
    }
    declare(module, LITERALS.into(), vec![Word::Int(0); count])?;
    // An empty table still has an address for image installation.
    if count == 0 {
        let Some(Data {
            contents: DataContents::Words(words),
            ..
        }) = module.data.last_mut()
        else {
            unreachable!()
        };
        words.push(Word::Int(0));
    }
    Ok(())
}
