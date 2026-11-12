//! kiln-cg as a library: KIR → machine code with Cranelift, for the
//! command-line tool (main.rs) and for code compiled into a running image
//! (`kiln_rt_compile_packet` and the legacy `kiln_rt_jit`, jit.rs).

pub mod codegen;
pub mod jit;
pub mod kir;
pub mod sexp;
pub mod packet;
