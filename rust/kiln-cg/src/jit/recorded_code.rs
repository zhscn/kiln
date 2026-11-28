//! Relocatable code in a process-local cache. Each use creates fresh data.
use cranelift_codegen::{Context, ir::Signature, isa::TargetIsa};
use cranelift_jit::JITModule;
use cranelift_module::{
    DataDescription, DataId, FuncId, Linkage, Module, ModuleDeclarations, ModuleReloc, ModuleResult,
};

struct FunctionBody {
    id: FuncId,
    alignment: u64,
    bytes: Vec<u8>,
    relocs: Vec<ModuleReloc>,
}

struct FunctionDecl {
    id: FuncId,
    name: Option<String>,
    linkage: Linkage,
    signature: Signature,
}

struct DataDecl {
    id: DataId,
    name: Option<String>,
    linkage: Linkage,
    writable: bool,
    tls: bool,
}

pub(super) struct RecordedCode {
    functions: Vec<FunctionDecl>,
    data: Vec<DataDecl>,
    bodies: Vec<FunctionBody>,
    definitions: Vec<(DataId, DataDescription)>,
}

impl RecordedCode {
    pub(super) fn payload_bytes(&self) -> usize {
        self.bodies
            .iter()
            .map(|body| body.bytes.len())
            .sum::<usize>()
            + self
                .definitions
                .iter()
                .map(|(_, data)| data.init.size())
                .sum::<usize>()
    }

    pub(super) fn replay(&self, module: &mut JITModule) -> Result<(), String> {
        let failure = |e: cranelift_module::ModuleError| e.to_string();
        for function in &self.functions {
            let id = match &function.name {
                Some(name) => module.declare_function(name, function.linkage, &function.signature),
                None => module.declare_anonymous_function(&function.signature),
            }
            .map_err(failure)?;
            if id != function.id {
                return Err("recorded function ID changed during installation".into());
            }
        }
        for data in &self.data {
            let id = match &data.name {
                Some(name) => module.declare_data(name, data.linkage, data.writable, data.tls),
                None => module.declare_anonymous_data(data.writable, data.tls),
            }
            .map_err(failure)?;
            if id != data.id {
                return Err("recorded data ID changed during installation".into());
            }
        }
        for (id, definition) in &self.definitions {
            module.define_data(*id, definition).map_err(failure)?;
        }
        for body in &self.bodies {
            module
                .define_function_bytes(body.id, body.alignment, &body.bytes, &body.relocs)
                .map_err(failure)?;
        }
        Ok(())
    }
}

pub(super) struct Recording {
    module: JITModule,
    bodies: Vec<FunctionBody>,
    definitions: Vec<(DataId, DataDescription)>,
}

impl Recording {
    pub(super) fn new(module: JITModule) -> Self {
        Self {
            module,
            bodies: Vec::new(),
            definitions: Vec::new(),
        }
    }

    pub(super) fn finish(self) -> (JITModule, RecordedCode) {
        let functions = self
            .module
            .declarations()
            .get_functions()
            .map(|(id, function)| FunctionDecl {
                id,
                name: function.name.clone(),
                linkage: function.linkage,
                signature: function.signature.clone(),
            })
            .collect();
        let data = self
            .module
            .declarations()
            .get_data_objects()
            .map(|(id, data)| DataDecl {
                id,
                name: data.name.clone(),
                linkage: data.linkage,
                writable: data.writable,
                tls: data.tls,
            })
            .collect();
        let code = RecordedCode {
            functions,
            data,
            bodies: self.bodies,
            definitions: self.definitions,
        };
        (self.module, code)
    }
}

impl Module for Recording {
    fn isa(&self) -> &dyn TargetIsa {
        self.module.isa()
    }

    fn declarations(&self) -> &ModuleDeclarations {
        self.module.declarations()
    }

    fn declare_function(
        &mut self,
        name: &str,
        linkage: Linkage,
        signature: &Signature,
    ) -> ModuleResult<FuncId> {
        self.module.declare_function(name, linkage, signature)
    }

    fn declare_anonymous_function(&mut self, signature: &Signature) -> ModuleResult<FuncId> {
        self.module.declare_anonymous_function(signature)
    }

    fn declare_data(
        &mut self,
        name: &str,
        linkage: Linkage,
        writable: bool,
        tls: bool,
    ) -> ModuleResult<DataId> {
        self.module.declare_data(name, linkage, writable, tls)
    }

    fn declare_anonymous_data(&mut self, writable: bool, tls: bool) -> ModuleResult<DataId> {
        self.module.declare_anonymous_data(writable, tls)
    }

    fn define_function_with_control_plane(
        &mut self,
        id: FuncId,
        context: &mut Context,
        control: &mut cranelift_codegen::control::ControlPlane,
    ) -> ModuleResult<()> {
        self.module
            .define_function_with_control_plane(id, context, control)?;
        let compiled = context
            .compiled_code()
            .expect("successful compilation has machine code");
        let alignment = (compiled.buffer.min_alignment as u64)
            .max(self.isa().function_alignment().minimum as u64)
            .max(self.isa().symbol_alignment());
        let relocs = compiled
            .buffer
            .relocs()
            .iter()
            .map(|reloc| ModuleReloc::from_mach_reloc(reloc, &context.func, id))
            .collect();
        self.bodies.push(FunctionBody {
            id,
            alignment,
            bytes: compiled.code_buffer().to_vec(),
            relocs,
        });
        Ok(())
    }

    fn define_function_bytes(
        &mut self,
        id: FuncId,
        alignment: u64,
        bytes: &[u8],
        relocs: &[ModuleReloc],
    ) -> ModuleResult<()> {
        self.module
            .define_function_bytes(id, alignment, bytes, relocs)?;
        self.bodies.push(FunctionBody {
            id,
            alignment,
            bytes: bytes.to_vec(),
            relocs: relocs.to_vec(),
        });
        Ok(())
    }

    fn define_data(&mut self, id: DataId, data: &DataDescription) -> ModuleResult<()> {
        self.module.define_data(id, data)?;
        self.definitions.push((id, data.clone()));
        Ok(())
    }
}
