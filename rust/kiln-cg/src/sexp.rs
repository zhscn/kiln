//! Minimal s-expression reader for KIR files.
//!
//! Atoms: integers (i64), symbols (bare identifiers, case-sensitive), and
//! strings ("..." with \" and \\ escapes). `;` starts a line comment.

use std::fmt;

#[derive(Clone, Debug, PartialEq)]
pub enum Sexp {
    Int(i64),
    Sym(String),
    Str(String),
    List(Vec<Sexp>),
}

#[derive(Debug)]
pub struct ParseError {
    pub pos: usize,
    pub msg: String,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "at byte {}: {}", self.pos, self.msg)
    }
}

impl std::error::Error for ParseError {}

struct Reader<'a> {
    src: &'a [u8],
    pos: usize,
}

impl Reader<'_> {
    fn err<T>(&self, msg: impl Into<String>) -> Result<T, ParseError> {
        Err(ParseError {
            pos: self.pos,
            msg: msg.into(),
        })
    }

    fn skip_ws(&mut self) {
        while self.pos < self.src.len() {
            match self.src[self.pos] {
                b' ' | b'\t' | b'\n' | b'\r' => self.pos += 1,
                b';' => {
                    while self.pos < self.src.len() && self.src[self.pos] != b'\n' {
                        self.pos += 1;
                    }
                }
                _ => break,
            }
        }
    }

    fn read(&mut self) -> Result<Sexp, ParseError> {
        self.skip_ws();
        let Some(&c) = self.src.get(self.pos) else {
            return self.err("unexpected end of input");
        };
        match c {
            b'(' => {
                self.pos += 1;
                let mut items = Vec::new();
                loop {
                    self.skip_ws();
                    match self.src.get(self.pos) {
                        None => return self.err("unterminated list"),
                        Some(b')') => {
                            self.pos += 1;
                            return Ok(Sexp::List(items));
                        }
                        Some(_) => items.push(self.read()?),
                    }
                }
            }
            b')' => self.err("unexpected ')'"),
            b'"' => {
                self.pos += 1;
                let mut bytes = Vec::new();
                loop {
                    match self.src.get(self.pos) {
                        None => return self.err("unterminated string"),
                        Some(b'"') => {
                            self.pos += 1;
                            break;
                        }
                        Some(b'\\') => {
                            let Some(&e) = self.src.get(self.pos + 1) else {
                                return self.err("unterminated escape");
                            };
                            bytes.push(e);
                            self.pos += 2;
                        }
                        Some(&b) => {
                            bytes.push(b);
                            self.pos += 1;
                        }
                    }
                }
                match String::from_utf8(bytes) {
                    Ok(s) => Ok(Sexp::Str(s)),
                    Err(_) => self.err("string is not valid UTF-8"),
                }
            }
            _ => {
                let start = self.pos;
                while self.pos < self.src.len()
                    && !matches!(
                        self.src[self.pos],
                        b' ' | b'\t' | b'\n' | b'\r' | b'(' | b')' | b'"' | b';'
                    )
                {
                    self.pos += 1;
                }
                let tok = std::str::from_utf8(&self.src[start..self.pos]).unwrap();
                match tok.parse::<i64>() {
                    Ok(n) => Ok(Sexp::Int(n)),
                    Err(_) => Ok(Sexp::Sym(tok.to_string())),
                }
            }
        }
    }
}

pub fn parse_one(src: &str) -> Result<Sexp, ParseError> {
    let mut r = Reader {
        src: src.as_bytes(),
        pos: 0,
    };
    let s = r.read()?;
    r.skip_ws();
    if r.pos != r.src.len() {
        return r.err("trailing input after top-level form");
    }
    Ok(s)
}

impl fmt::Display for Sexp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Sexp::Int(n) => write!(f, "{n}"),
            Sexp::Sym(s) => write!(f, "{s}"),
            Sexp::Str(s) => {
                write!(f, "\"")?;
                for c in s.chars() {
                    if c == '\\' || c == '"' { write!(f, "\\")?; }
                    write!(f, "{c}")?;
                }
                write!(f, "\"")
            }
            Sexp::List(items) => {
                write!(f, "(")?;
                for (i, it) in items.iter().enumerate() {
                    if i > 0 {
                        write!(f, " ")?;
                    }
                    write!(f, "{it}")?;
                }
                write!(f, ")")
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn diagnostic_strings_roundtrip_control_characters() {
        let value = Sexp::List(vec![Sexp::Str("line\n\r\t\0\\\"λ".into())]);
        assert_eq!(parse_one(&value.to_string()).unwrap(), value);
    }

    #[test]
    fn parses_nested() {
        let s = parse_one("(a -12 \"x\\\"y\" (b)) ; c").unwrap();
        assert_eq!(
            s,
            Sexp::List(vec![
                Sexp::Sym("a".into()),
                Sexp::Int(-12),
                Sexp::Str("x\"y".into()),
                Sexp::List(vec![Sexp::Sym("b".into())]),
            ])
        );
    }
}
