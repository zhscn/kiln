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
    let mut hash = 0xcbf29ce484222325u64;
    for bytes in [
        include_bytes!("../../kiln-rt/src/object.rs").as_slice(),
        include_bytes!("../../kiln-rt/src/context.rs").as_slice(),
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
    if n == 0 || u32_at(bytes, 52) as usize != n - 1 || ne != n - 1 {
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
                    if child >= id || parents[child] != 0 {
                        return Err("backend packet: invalid child ownership".into());
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
                        nodes[u32_at(bytes, edge_start + edge * 4) as usize]
                            .take()
                            .unwrap()
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

pub fn encode(program: &Sexp, language: u32) -> Result<Vec<u8>, String> {
    struct Encoder {
        records: Vec<[u8; 16]>,
        edges: Vec<u32>,
        strings: Vec<u8>,
    }
    impl Encoder {
        fn node(&mut self, node: &Sexp, depth: u32) -> Result<u32, String> {
            if depth > MAX_DEPTH {
                return Err("backend packet: nesting limit exceeded".into());
            }
            let (tag, a, b) = match node {
                Sexp::Int(n) => (INTEGER, 0, *n as u64),
                Sexp::Sym(s) | Sexp::Str(s) => {
                    let offset = self.strings.len();
                    self.strings.extend_from_slice(s.as_bytes());
                    (
                        if matches!(node, Sexp::Sym(_)) {
                            SYMBOL
                        } else {
                            STRING
                        },
                        offset,
                        s.len() as u64,
                    )
                }
                Sexp::List(items) => {
                    let children = items
                        .iter()
                        .map(|item| self.node(item, depth + 1))
                        .collect::<Result<Vec<_>, _>>()?;
                    let offset = self.edges.len();
                    self.edges.extend(children);
                    (LIST, offset, items.len() as u64)
                }
            };
            let id = u32::try_from(self.records.len())
                .map_err(|_| "backend packet: too many records")?;
            let a = u32::try_from(a).map_err(|_| "backend packet: section too large")?;
            let mut record = [0; 16];
            record[..4].copy_from_slice(&tag.to_le_bytes());
            record[4..8].copy_from_slice(&a.to_le_bytes());
            record[8..].copy_from_slice(&b.to_le_bytes());
            self.records.push(record);
            let size = HEADER_SIZE as usize
                + self.records.len() * 16
                + self.edges.len() * 4
                + self.strings.len();
            if size > MAX_BYTES as usize {
                return Err("backend packet: size limit exceeded".into());
            }
            Ok(id)
        }
    }
    if ![KIR_PAYLOAD, LIR_PAYLOAD].contains(&language) {
        return Err("backend packet: unknown language".into());
    }
    let mut enc = Encoder {
        records: vec![],
        edges: vec![],
        strings: vec![],
    };
    let root = enc.node(program, 1)?;
    let mut out = Vec::with_capacity(
        HEADER_SIZE as usize + enc.records.len() * 16 + enc.edges.len() * 4 + enc.strings.len(),
    );
    out.extend_from_slice(MAGIC);
    for n in [MAJOR, MINOR, language, 0] {
        out.extend_from_slice(&n.to_le_bytes());
    }
    out.extend_from_slice(&target_fingerprint().to_le_bytes());
    out.extend_from_slice(&0u64.to_le_bytes());
    for n in [
        enc.records.len() as u32,
        enc.edges.len() as u32,
        enc.strings.len() as u32,
        root,
    ] {
        out.extend_from_slice(&n.to_le_bytes());
    }
    out.extend_from_slice(&0u64.to_le_bytes());
    for record in enc.records {
        out.extend_from_slice(&record);
    }
    for edge in enc.edges {
        out.extend_from_slice(&edge.to_le_bytes());
    }
    out.extend(enc.strings);
    let total = out.len() as u64;
    out[32..40].copy_from_slice(&total.to_le_bytes());
    Ok(out)
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
