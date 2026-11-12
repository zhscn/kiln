//! Binary backend requests. Record IDs refer only to earlier records;
//! owning child references make decoding linear without expanding a DAG.
use crate::sexp::Sexp;

pub mod schema {
    include!("packet_schema.rs");
}
use schema::*;
pub const MAGIC: &[u8; 8] = b"KILNLIR\0";

/// Identifies the target runtime build, including its value and context
/// definitions. This is deliberately stricter than layout compatibility.
pub fn target_fingerprint() -> u64 {
    static VALUE: std::sync::OnceLock<u64> = std::sync::OnceLock::new();
    *VALUE.get_or_init(compute_target_fingerprint)
}

fn compute_target_fingerprint() -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for bytes in [
        include_bytes!("../../kiln-rt/src/object.rs").as_slice(),
        include_bytes!("../../kiln-rt/src/context.rs").as_slice(),
        include_bytes!("packet_schema.rs").as_slice(),
        std::env::consts::ARCH.as_bytes(),
        std::env::consts::OS.as_bytes(),
    ] {
        for &byte in bytes {
            hash = (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3);
        }
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn u32_at(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
}
fn u64_at(bytes: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(bytes[at..at + 8].try_into().unwrap())
}

pub struct Request {
    pub language: u32,
    pub program: Sexp,
}

/// Validate lengths and ownership before allocating the decoded tree.
pub fn decode(bytes: &[u8]) -> Result<Request, String> {
    if bytes.len() < HEADER_SIZE as usize || bytes.len() > MAX_BYTES as usize {
        return Err("backend packet: invalid length".into());
    }
    if &bytes[..8] != MAGIC || u32_at(bytes, 8) != MAJOR || u32_at(bytes, 12) != MINOR {
        return Err("backend packet: unsupported magic or schema".into());
    }
    let language = u32_at(bytes, 16);
    if ![KIR_PAYLOAD, LIR_PAYLOAD].contains(&language) || u32_at(bytes, 20) != 0 {
        return Err("backend packet: unsupported payload or flags".into());
    }
    if u64_at(bytes, 24) != target_fingerprint() {
        return Err("backend packet: target ABI fingerprint mismatch".into());
    }
    if u64_at(bytes, 32) != bytes.len() as u64 || u64_at(bytes, 56) != 0 {
        return Err("backend packet: invalid total length or reserved bits".into());
    }
    let n = u32_at(bytes, 40) as usize;
    let ne = u32_at(bytes, 44) as usize;
    let ns = u32_at(bytes, 48) as usize;
    if n == 0 || u32_at(bytes, 52) as usize != n - 1 || ne < n - 1 {
        return Err("backend packet: invalid root or edge count".into());
    }
    let edge_start = (HEADER_SIZE as usize)
        .checked_add(
            n.checked_mul(RECORD_SIZE as usize)
                .ok_or("backend packet: record size overflow")?,
        )
        .ok_or("backend packet: size overflow")?;
    let string_start = edge_start
        .checked_add(
            ne.checked_mul(4)
                .ok_or("backend packet: edge size overflow")?,
        )
        .ok_or("backend packet: size overflow")?;
    if string_start.checked_add(ns) != Some(bytes.len()) {
        return Err("backend packet: section lengths do not match".into());
    }
    let mut expansion = (n + ne) as u64 * u64::from(EXPANSION_RECORD_BYTES) + ns as u64;
    if expansion > u64::from(MAX_EXPANDED_BYTES) {
        return Err("backend packet: expansion limit exceeded".into());
    }
    let mut parents = vec![0u8; n];
    let mut depths = vec![0u32; n];
    let mut next_edge = 0;
    let mut next_string = 0;
    for id in 0..n {
        let at = HEADER_SIZE as usize + id * RECORD_SIZE as usize;
        let tag = u32_at(bytes, at);
        let a = u32_at(bytes, at + 4) as usize;
        let b = u64_at(bytes, at + 8);
        let mut depth = 1;
        match tag {
            INTEGER if a == 0 => {}
            SYMBOL | STRING => {
                let len =
                    usize::try_from(b).map_err(|_| "backend packet: string length overflow")?;
                let end = a
                    .checked_add(len)
                    .ok_or("backend packet: string range overflow")?;
                if a != next_string || end > ns {
                    return Err("backend packet: invalid string range".into());
                }
                std::str::from_utf8(&bytes[string_start + a..string_start + end])
                    .map_err(|_| "backend packet: invalid UTF-8")?;
                next_string = end;
            }
            LIST => {
                let len = usize::try_from(b).map_err(|_| "backend packet: list length overflow")?;
                let end = a
                    .checked_add(len)
                    .ok_or("backend packet: edge range overflow")?;
                if a != next_edge || end > ne {
                    return Err("backend packet: invalid edge range".into());
                }
                for edge in a..end {
                    let child = u32_at(bytes, edge_start + edge * 4) as usize;
                    if child >= id {
                        return Err("backend packet: invalid child ID".into());
                    }
                    let child_at = HEADER_SIZE as usize + child * RECORD_SIZE as usize;
                    let child_tag = u32_at(bytes, child_at);
                    let child_size = u64_at(bytes, child_at + 8);
                    if parents[child] != 0 && child_tag == LIST && child_size != 0 {
                        return Err("backend packet: shared nonempty list".into());
                    }
                    if child_tag == SYMBOL || child_tag == STRING {
                        expansion += child_size;
                        if expansion > u64::from(MAX_EXPANDED_BYTES) {
                            return Err("backend packet: expansion limit exceeded".into());
                        }
                    }
                    parents[child] = 1;
                    depth = depth.max(depths[child] + 1);
                }
                next_edge = end;
            }
            _ => return Err("backend packet: invalid record tag or reserved bits".into()),
        }
        if depth > MAX_DEPTH {
            return Err("backend packet: nesting limit exceeded".into());
        }
        depths[id] = depth;
    }
    if next_edge != ne || next_string != ns || parents[..n - 1].contains(&0) {
        return Err("backend packet: unused records or section data".into());
    }
    let mut nodes: Vec<Option<Sexp>> = Vec::with_capacity(n);
    for id in 0..n {
        let at = HEADER_SIZE as usize + id * RECORD_SIZE as usize;
        let tag = u32_at(bytes, at);
        let a = u32_at(bytes, at + 4) as usize;
        let b = u64_at(bytes, at + 8);
        let node = match tag {
            INTEGER => Sexp::Int(b as i64),
            SYMBOL | STRING => {
                let text =
                    std::str::from_utf8(&bytes[string_start + a..string_start + a + b as usize])
                        .unwrap()
                        .to_owned();
                if tag == SYMBOL {
                    Sexp::Sym(text)
                } else {
                    Sexp::Str(text)
                }
            }
            LIST => Sexp::List(
                (a..a + b as usize)
                    .map(|edge| {
                        let child = u32_at(bytes, edge_start + edge * 4) as usize;
                        match nodes[child].as_ref().unwrap() {
                            Sexp::List(items) if !items.is_empty() => nodes[child].take().unwrap(),
                            atom => atom.clone(),
                        }
                    })
                    .collect(),
            ),
            _ => unreachable!(),
        };
        nodes.push(Some(node));
    }
    Ok(Request {
        language,
        program: nodes.pop().unwrap().unwrap(),
    })
}

/// Canonical records shared by portable-file and native-heap adapters.
#[derive(Default)]
pub(crate) struct RecordBuilder {
    records: Vec<[u8; 16]>,
    edges: Vec<u32>,
    strings: Vec<u8>,
    symbols: std::collections::HashMap<String, u32>,
    texts: std::collections::HashMap<String, u32>,
    integers: std::collections::HashMap<i64, u32>,
    empty: Option<u32>,
    expanded_strings: u64,
}

impl RecordBuilder {
    fn check(&self) -> Result<(), String> {
        let size = HEADER_SIZE as usize
            + self.records.len() * 16
            + self.edges.len() * 4
            + self.strings.len();
        if size > MAX_BYTES as usize {
            return Err("backend packet: size limit exceeded".into());
        }
        let expanded = (self.records.len() + self.edges.len()) as u64
            * u64::from(EXPANSION_RECORD_BYTES)
            + self.strings.len() as u64
            + self.expanded_strings;
        if expanded > u64::from(MAX_EXPANDED_BYTES) {
            return Err("backend packet: expansion limit exceeded".into());
        }
        Ok(())
    }
    fn record(&mut self, tag: u32, a: usize, b: u64) -> Result<u32, String> {
        let id =
            u32::try_from(self.records.len()).map_err(|_| "backend packet: too many records")?;
        let a = u32::try_from(a).map_err(|_| "backend packet: section too large")?;
        let mut record = [0; 16];
        record[..4].copy_from_slice(&tag.to_le_bytes());
        record[4..8].copy_from_slice(&a.to_le_bytes());
        record[8..].copy_from_slice(&b.to_le_bytes());
        self.records.push(record);
        self.check()?;
        Ok(id)
    }
    pub(crate) fn integer(&mut self, n: i64) -> Result<u32, String> {
        if let Some(id) = self.integers.get(&n) {
            return Ok(*id);
        }
        let id = self.record(INTEGER, 0, n as u64)?;
        self.integers.insert(n, id);
        Ok(id)
    }
    pub(crate) fn text(&mut self, text: &str, symbol: bool) -> Result<u32, String> {
        let table = if symbol { &self.symbols } else { &self.texts };
        if let Some(id) = table.get(text) {
            return Ok(*id);
        }
        let offset = self.strings.len();
        if offset + text.len() > MAX_BYTES as usize {
            return Err("backend packet: string limit exceeded".into());
        }
        self.strings.extend_from_slice(text.as_bytes());
        let id = self.record(
            if symbol { SYMBOL } else { STRING },
            offset,
            text.len() as u64,
        )?;
        if symbol {
            self.symbols.insert(text.to_owned(), id);
        } else {
            self.texts.insert(text.to_owned(), id);
        }
        Ok(id)
    }
    pub(crate) fn list(&mut self, children: &[u32]) -> Result<u32, String> {
        if children.is_empty()
            && let Some(id) = self.empty
        {
            return Ok(id);
        }
        for &child in children {
            let row = self
                .records
                .get(child as usize)
                .ok_or("backend packet: invalid child")?;
            if [SYMBOL, STRING].contains(&u32_at(row, 0)) {
                self.expanded_strings += u64_at(row, 8);
            }
        }
        let offset = self.edges.len();
        self.edges.extend_from_slice(children);
        let id = self.record(LIST, offset, children.len() as u64)?;
        if children.is_empty() {
            self.empty = Some(id);
        }
        Ok(id)
    }
    pub(crate) fn finish(self, root: u32, language: u32) -> Result<Vec<u8>, String> {
        self.check()?;
        if ![KIR_PAYLOAD, LIR_PAYLOAD].contains(&language) {
            return Err("backend packet: unknown language".into());
        }
        let mut out = Vec::with_capacity(
            HEADER_SIZE as usize
                + self.records.len() * 16
                + self.edges.len() * 4
                + self.strings.len(),
        );
        out.extend_from_slice(MAGIC);
        for n in [MAJOR, MINOR, language, 0] {
            out.extend_from_slice(&n.to_le_bytes());
        }
        out.extend_from_slice(&target_fingerprint().to_le_bytes());
        out.extend_from_slice(&0u64.to_le_bytes());
        for n in [
            self.records.len() as u32,
            self.edges.len() as u32,
            self.strings.len() as u32,
            root,
        ] {
            out.extend_from_slice(&n.to_le_bytes());
        }
        out.extend_from_slice(&0u64.to_le_bytes());
        for row in self.records {
            out.extend_from_slice(&row);
        }
        for edge in self.edges {
            out.extend_from_slice(&edge.to_le_bytes());
        }
        out.extend(self.strings);
        let size = out.len() as u64;
        out[32..40].copy_from_slice(&size.to_le_bytes());
        Ok(out)
    }
}

pub fn encode(program: &Sexp, language: u32) -> Result<Vec<u8>, String> {
    fn node(builder: &mut RecordBuilder, value: &Sexp, depth: u32) -> Result<u32, String> {
        if depth > MAX_DEPTH {
            return Err("backend packet: nesting limit exceeded".into());
        }
        match value {
            Sexp::Int(n) => builder.integer(*n),
            Sexp::Sym(text) => builder.text(text, true),
            Sexp::Str(text) => builder.text(text, false),
            Sexp::List(items) => {
                let children = items
                    .iter()
                    .map(|item| node(builder, item, depth + 1))
                    .collect::<Result<Vec<_>, _>>()?;
                builder.list(&children)
            }
        }
    }
    let mut builder = RecordBuilder::default();
    let root = node(&mut builder, program, 1)?;
    builder.finish(root, language)
}

pub fn load(bytes: &[u8]) -> Result<crate::kir::Module, String> {
    let request = decode(bytes)?;
    if request.language != KIR_PAYLOAD {
        return Err("LIR operations are not supported by this backend yet".into());
    }
    crate::kir::parse_module(&request.program)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn roundtrip_and_every_truncation() {
        let form = crate::sexp::parse_one("(module \"λ\\\"\\\\\" (data \"n\" (words -9223372036854775808 9223372036854775807)) ())").unwrap();
        let bytes = encode(&form, KIR_PAYLOAD).unwrap();
        assert_eq!(decode(&bytes).unwrap().program, form);
        for end in 0..bytes.len() {
            assert!(decode(&bytes[..end]).is_err(), "length {end}");
        }
        assert_eq!(encode(&form, KIR_PAYLOAD).unwrap(), bytes);
    }
    #[test]
    fn pools_atoms_but_bounds_decoded_expansion() {
        let form = Sexp::List(vec![Sexp::Str("x".repeat(1 << 20)); 2]);
        let mut bytes = encode(&form, KIR_PAYLOAD).unwrap();
        assert_eq!(u32_at(&bytes, 40), 2);
        let strings = bytes[(HEADER_SIZE + 2 * RECORD_SIZE + 2 * 4) as usize..].to_vec();
        bytes.truncate((HEADER_SIZE + 2 * RECORD_SIZE) as usize);
        bytes[(HEADER_SIZE + RECORD_SIZE + 8) as usize..(HEADER_SIZE + 2 * RECORD_SIZE) as usize]
            .copy_from_slice(&2048u64.to_le_bytes());
        for _ in 0..2048 {
            bytes.extend_from_slice(&0u32.to_le_bytes());
        }
        bytes.extend(strings);
        bytes[44..48].copy_from_slice(&2048u32.to_le_bytes());
        let size = bytes.len() as u64;
        bytes[32..40].copy_from_slice(&size.to_le_bytes());
        assert!(decode(&bytes).err().unwrap().contains("expansion"));
    }

    #[test]
    fn collections_cannot_be_shared() {
        let form = crate::sexp::parse_one("((42) (43))").unwrap();
        let mut bytes = encode(&form, KIR_PAYLOAD).unwrap();
        let edges = (HEADER_SIZE + 5 * RECORD_SIZE) as usize;
        bytes[edges + 12..edges + 16].copy_from_slice(&1u32.to_le_bytes());
        assert!(
            decode(&bytes)
                .err()
                .unwrap()
                .contains("shared nonempty list")
        );
    }

    #[test]
    fn malformed_programs_return_errors() {
        for text in [
            "(module \"m\" (init \"i\") (data \"x\" (words (data))))",
            "(module \"m\" (init \"i\") (func \"f\" (vars) (slots) (block b (return (addr) 1))))",
        ] {
            let program = crate::sexp::parse_one(text).unwrap();
            assert!(load(&encode(&program, KIR_PAYLOAD).unwrap()).is_err());
        }
    }

    #[test]
    fn rejects_corruption_without_panicking() {
        let form = crate::sexp::parse_one("(x (y 12) \"λ\")").unwrap();
        let bytes = encode(&form, KIR_PAYLOAD).unwrap();
        for i in 0..bytes.len() {
            let mut bad = bytes.clone();
            bad[i] ^= 255;
            let _ = decode(&bad);
        }
        let mut bad = bytes.clone();
        bad[24] ^= 1;
        assert!(decode(&bad).err().unwrap().contains("fingerprint"));
        let mut deep = Sexp::Int(0);
        for _ in 0..MAX_DEPTH {
            deep = Sexp::List(vec![deep]);
        }
        assert!(encode(&deep, KIR_PAYLOAD).is_err());
    }
}
