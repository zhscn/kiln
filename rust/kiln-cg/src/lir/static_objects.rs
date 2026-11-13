//! Static scalar objects, independent of the input adapter.
use crate::kir::Word;
use kiln_rt::object::{KIND_BIGNUM, LENGTH_SHIFT};
use num_bigint::BigInt;

pub fn integer_words(value: &BigInt) -> Vec<Word> {
    let mut bytes = value.to_signed_bytes_le();
    bytes.resize(
        bytes.len().next_multiple_of(8),
        if value < &BigInt::from(0) { 255 } else { 0 },
    );
    let mut words = vec![Word::Int(
        (KIND_BIGNUM | ((bytes.len() as u64 / 8) << LENGTH_SHIFT)) as i64,
    )];
    words.extend(
        bytes
            .as_chunks::<8>()
            .0
            .iter()
            .map(|b| Word::Int(i64::from_le_bytes(*b))),
    );
    words
}
