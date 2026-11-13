//! Closed runtime services and their ABI and transfer-area effects.
use crate::kir::{self, Expr, ImportFunc, Loc, Stmt, VarKind};
use std::collections::HashSet;

pub(crate) struct Descriptor {
    pub entry: &'static str,
    pub arguments: usize,
    pub safepoint: bool,
}
macro_rules! operations {
    ($( $variant:ident => ($name:literal,$entry:literal,$args:literal,$safepoint:literal), )*) => {
        #[derive(Clone,Copy,Debug)]
        pub enum RuntimeOperation { $( $variant, )* }
        impl RuntimeOperation {
            pub(crate) const ALL: &'static [Self] = &[$(Self::$variant,)*];
            pub(crate) fn parse(name:&str) -> Option<Self> {match name { $($name=>Some(Self::$variant),)* _=>None }}
            pub(crate) fn descriptor(self) -> Descriptor {match self { $(Self::$variant=>Descriptor {entry:$entry,arguments:$args,safepoint:$safepoint},)*}}
        }
    }
}
operations! {
    Print => ("print","kiln_rt_print",1,false),
    Gc => ("gc","kiln_rt_gc",0,true),
    GcCount => ("gc-count","kiln_rt_gc_count",0,false),
    NewStack => ("call-on-new-stack","kiln_rt_call_on_new_stack",2,true),
    IdentityHash => ("identity-hash","kiln_rt_identity_hash",1,false),
    FdWrite => ("fd-write","kiln_rt_fd_write",4,false),
    FdRead => ("fd-read","kiln_rt_fd_read",4,false),
    System => ("sys","kiln_rt_sys",4,false),
    WriteKir => ("write-kir","kiln_rt_write_kir",2,false),
    Jit => ("jit","kiln_rt_jit",2,false),
    WritePacket => ("write-packet","kiln_rt_write_packet",2,false),
    EncodePacket => ("encode-packet","kiln_rt_encode_packet",2,true),
    CompileProgram => ("compile-program","kiln_rt_compile_program",3,false),
    CompilePacket => ("compile-packet","kiln_rt_compile_packet",2,false),
    SaveImage => ("save-image","kiln_rt_save_image",3,false),
    Frame => ("frame","kiln_rt_frame",3,false),
    FloatDecimal => ("float-decimal","kiln_rt_float_decimal",2,false),
}
type Expansion = (Vec<(String, VarKind)>, Vec<kir::Block>, String, Vec<Stmt>);
impl RuntimeOperation {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn lower(
        self,
        prefix: &str,
        start: String,
        mut before: Vec<Stmt>,
        result: String,
        mut args: Vec<Expr>,
        handler: Option<String>,
        loc: Option<Loc>,
    ) -> Result<Expansion, String> {
        let descriptor = self.descriptor();
        if args.len() != descriptor.arguments {
            return Err("wrong runtime operation arity".into());
        }
        let handler = if descriptor.safepoint { handler } else { None };
        if matches!(self, Self::IdentityHash) {
            let object = format!("{prefix}_input");
            before.push(Stmt::Set(object.clone(), args.remove(0)));
            let (mut vars, mut blocks, next) = crate::lir::identity_hash(
                prefix,
                start,
                before,
                result,
                object.clone(),
                descriptor.entry.into(),
            );
            vars.push((object, VarKind::Obj));
            for statement in blocks.iter_mut().flat_map(|b| &mut b.stmts) {
                if let Stmt::CallRt { loc: site, .. } = statement {
                    *site = loc;
                }
            }
            return Ok((vars, blocks, next, vec![]));
        }
        args.insert(0, Expr::Var("ctx".into()));
        before.push(Stmt::CallRt {
            name: descriptor.entry.into(),
            results: vec![result],
            args,
            handler,
            loc,
        });
        Ok((vec![], vec![], start, before))
    }
}

pub(crate) fn register_imports(module: &mut kir::Module) -> Result<(), String> {
    let calls: HashSet<_> = module
        .funcs
        .iter()
        .flat_map(|f| &f.blocks)
        .flat_map(|b| &b.stmts)
        .filter_map(|s| {
            if let Stmt::CallRt { name, .. } = s {
                Some(name.as_str())
            } else {
                None
            }
        })
        .collect();
    for operation in RuntimeOperation::ALL {
        let descriptor = operation.descriptor();
        if !calls.contains(descriptor.entry) {
            continue;
        }
        if let Some(import) = module
            .import_funcs
            .iter()
            .find(|f| f.name == descriptor.entry)
        {
            if import.params != descriptor.arguments + 1
                || import.returns != 1
                || import.unwinds != descriptor.safepoint
                || import.noreturn
            {
                return Err(format!(
                    "runtime operation requires the signature of {}",
                    descriptor.entry
                ));
            }
        } else {
            module.import_funcs.push(ImportFunc {
                name: descriptor.entry.into(),
                params: descriptor.arguments + 1,
                returns: 1,
                unwinds: descriptor.safepoint,
                noreturn: false,
            });
        }
    }
    Ok(())
}
