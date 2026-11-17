//! Production LIR validation and lowering, internal KIR code generation, and
//! owned image compilation. Compatibility KIR belongs to diagnostic dispatch.

pub mod codegen;
pub mod jit;
pub mod kir;
pub mod sexp;
pub mod packet;
pub mod lir;
mod packet_heap;
