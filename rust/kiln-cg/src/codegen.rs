//! KIR → Cranelift, generic over the JIT and object backends.

use crate::kir::{self, BinOp, CmpOp, DataContents, DebugRef, Expr, Loc, OvfOp, ShiftOp, Stmt, VarKind, Word};
use cranelift_codegen::ir::{
    self, AbiParam, BlockArg, ExceptionTableData, ExceptionTableItem, InstBuilder,
    MemFlagsData,
    Signature, StackSlotData, StackSlotKind, TrapCode, Value, condcodes::IntCC, types::I64,
};
use cranelift_codegen::isa::CallConv;
use cranelift_codegen::{Context, ir::BlockCall};
use cranelift_frontend::{FunctionBuilder, FunctionBuilderContext, Switch, Variable};
use cranelift_module::{DataDescription, DataId, FuncId, Linkage, Module};
use std::collections::HashMap;

/// Exported System V entry trampoline: (ctx, fobj, entry, nargs, a0) ->
/// primary value.
pub const ENTER_NAME: &str = "kiln_enter";
pub const MODULE_INFO_NAME: &str = "kiln_module_info";

/// One call site with a handler, relative to its function.
#[derive(Debug, Clone, Copy)]
pub struct CallSiteInfo {
    pub func: FuncId,
    pub ret_off: u32,
    pub handler_off: u32,
    pub frame_offset: u32,
}

/// Slots holding Lisp objects at one call site, as offsets from the SP at
/// the call.
#[derive(Debug, Clone)]
pub struct StackMapInfo {
    pub func: FuncId,
    pub ret_off: u32,
    pub offsets: Vec<u32>,
}

/// Debug information of one function: its debug info object
/// and its call sites' source locations and variables, encoded as
/// `kiln_rt::debug` reads them.
pub struct FuncDebug {
    pub func: FuncId,
    pub len: u32,
    pub info: Option<DebugInfo>,
    pub sites: Vec<u8>,
}

/// Where the debug info object of a function is.
#[derive(Clone, Copy)]
pub enum DebugInfo {
    /// The object is this word (an immediate)...
    Word(i64),
    /// ... or the static object at this address (data + addend)...
    Data(DataId, i64),
    /// ... or the object held in this word.
    Indirect(DataId, i64),
}

pub struct Output {
    pub enter: FuncId,
    pub inits: Vec<DataId>,
    pub callsites: Vec<CallSiteInfo>,
    pub stackmaps: Vec<StackMapInfo>,
    /// Static GC roots: (data object, byte offset).
    pub roots: Vec<(DataId, u32)>,
    /// The definitions named in `kiln_rt::EXPORTED_NAMES` that the module
    /// defines.
    pub exports: Vec<(String, Ref)>,
    /// All data objects the module defines, by name.
    pub data: HashMap<String, DataId>,
    pub debug: Vec<FuncDebug>,
}

#[derive(Clone, Copy)]
pub enum Ref {
    Func(FuncId),
    Data(DataId),
}

pub struct Options {
    pub dump_clif: bool,
}

type R<T> = Result<T, String>;

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

pub fn lisp_signature(cc: CallConv) -> Signature {
    let mut sig = Signature::new(cc);
    for _ in 0..3 + kir::REG_ARGS {
        sig.params.push(AbiParam::new(I64));
    }
    sig.returns.push(AbiParam::new(I64));
    sig.returns.push(AbiParam::new(I64));
    sig
}

fn word_signature(cc: CallConv, params: usize, returns: usize) -> Signature {
    let mut sig = Signature::new(cc);
    sig.params.extend((0..params).map(|_| AbiParam::new(I64)));
    sig.returns.extend((0..returns).map(|_| AbiParam::new(I64)));
    sig
}

fn trampoline_name(import: &str) -> String {
    format!("__kiln_t_{import}")
}

struct Imports<'a> {
    by_name: HashMap<&'a str, &'a kir::ImportFunc>,
    trampolines: HashMap<&'a str, FuncId>,
}

pub fn compile<M: Module>(module: &mut M, kir: &kir::Module, opts: &Options) -> R<Output> {
    let sysv = module.isa().default_call_conv();
    let lisp_sig = lisp_signature(CallConv::Tail);
    let mut names: HashMap<String, Ref> = HashMap::new();

    // Declarations.
    let mut imports = Imports {
        by_name: HashMap::new(),
        trampolines: HashMap::new(),
    };
    for f in &kir.import_funcs {
        let extra = usize::from(f.unwinds);
        let sig = word_signature(sysv, f.params + extra, f.returns);
        let id = module
            .declare_function(&f.name, Linkage::Import, &sig)
            .map_err(err)?;
        names.insert(f.name.clone(), Ref::Func(id));
        imports.by_name.insert(&f.name, f);
        if f.unwinds {
            let tsig = word_signature(CallConv::Tail, f.params, f.returns);
            let tid = module
                .declare_function(&trampoline_name(&f.name), Linkage::Local, &tsig)
                .map_err(err)?;
            imports.trampolines.insert(&f.name, tid);
        }
    }
    for d in &kir.import_data {
        let id = module
            .declare_data(d, Linkage::Import, false, false)
            .map_err(err)?;
        names.insert(d.clone(), Ref::Data(id));
    }
    for d in &kir.data {
        let id = module
            .declare_data(&d.name, Linkage::Local, true, false)
            .map_err(err)?;
        names.insert(d.name.clone(), Ref::Data(id));
    }
    let mut func_ids = Vec::new();
    for f in &kir.funcs {
        let id = module
            .declare_function(&f.name, Linkage::Local, &lisp_sig)
            .map_err(err)?;
        names.insert(f.name.clone(), Ref::Func(id));
        func_ids.push(id);
    }
    let enter_sig = word_signature(sysv, 5, 1);
    let enter = module
        .declare_function(ENTER_NAME, Linkage::Export, &enter_sig)
        .map_err(err)?;

    // Data.
    for d in &kir.data {
        let Some(Ref::Data(id)) = names.get(&d.name).copied() else {
            unreachable!()
        };
        let mut desc = DataDescription::new();
        desc.set_align(8);
        match &d.contents {
            DataContents::Bytes(b) => {
                let mut bytes = b.clone();
                bytes.push(0);
                desc.define(bytes.into_boxed_slice());
            }
            DataContents::Words(words) => {
                let mut bytes = vec![0u8; words.len() * 8];
                for (i, w) in words.iter().enumerate() {
                    let off = (i * 8) as u32;
                    match w {
                        Word::Int(n) => {
                            bytes[i * 8..i * 8 + 8].copy_from_slice(&n.to_le_bytes());
                        }
                        Word::DataAddr(name, addend) => match names.get(name) {
                            Some(Ref::Data(target)) => {
                                let gv = module.declare_data_in_data(*target, &mut desc);
                                desc.write_data_addr(off, gv, *addend);
                            }
                            _ => return Err(format!("data {}: unknown data {name}", d.name)),
                        },
                        Word::FuncAddr(name) => match names.get(name) {
                            Some(Ref::Func(target)) => {
                                let fr = module.declare_func_in_data(*target, &mut desc);
                                desc.write_function_addr(off, fr);
                            }
                            _ => return Err(format!("data {}: unknown function {name}", d.name)),
                        },
                    }
                }
                desc.define(bytes.into_boxed_slice());
            }
        }
        module.define_data(id, &desc).map_err(err)?;
    }

    // Functions: the CLIF is built here, one function after another (it
    // needs the module for references); the functions are compiled to
    // machine code on all cores, then defined in order.
    let mut fctx = FunctionBuilderContext::new();
    let mut callsites = Vec::new();
    let mut stackmaps = Vec::new();
    let mut funcs = Vec::with_capacity(kir.funcs.len());
    let mut debug_ir = Vec::with_capacity(kir.funcs.len());
    for f in &kir.funcs {
        let mut func = ir::Function::new();
        func.signature = lisp_sig.clone();
        let mut lw = FuncLowering {
            module,
            names: &names,
            imports: &imports,
            lisp_sig: &lisp_sig,
            vars: HashMap::new(),
            var_kinds: HashMap::new(),
            slots: HashMap::new(),
            blocks: HashMap::new(),
            landings: HashMap::new(),
            func_refs: HashMap::new(),
            data_gvs: HashMap::new(),
            lisp_sigref: None,
            labels: f.labels.iter().cloned().collect(),
            value_labels: HashMap::new(),
            call_locs: Vec::new(),
        };
        lw.build(&mut func, &mut fctx, f)
            .map_err(|e| format!("func {}: {e}", f.name))?;
        let slots = debug_slots(&func, &lw.value_labels, lw.call_locs.len());
        debug_ir.push((std::mem::take(&mut lw.call_locs), slots));
        if opts.dump_clif {
            eprintln!("; {}\n{}", f.name, func.display());
        }
        funcs.push(func);
    }
    let timing = std::env::var("KILN_TIME").is_ok();
    let t = std::time::Instant::now();
    let contexts = compile_parallel(module.isa(), funcs, &kir.funcs)?;
    if timing {
        eprintln!("kiln-cg: machine code in {:?}", t.elapsed());
    }
    let min_align = (module.isa().function_alignment().minimum as u64)
        .max(module.isa().symbol_alignment());
    let mut debug = Vec::new();
    for (((ctx, &id), f), (locs, slots)) in contexts.iter().zip(&func_ids).zip(&kir.funcs).zip(&debug_ir) {
        let code = ctx.compiled_code().ok_or("no compiled code")?;
        let relocs: Vec<_> = code
            .buffer
            .relocs()
            .iter()
            .map(|r| cranelift_module::ModuleReloc::from_mach_reloc(r, &ctx.func, id))
            .collect();
        let align = (code.buffer.min_alignment as u64).max(min_align);
        module
            .define_function_bytes(id, align, code.code_buffer(), &relocs)
            .map_err(|e| format!("func {id}: {e:?}"))?;
        collect_callsites(ctx, id, &mut callsites)?;
        collect_stackmaps(ctx, id, &mut stackmaps)?;
        let info = match &f.debug {
            None => None,
            Some(DebugRef::Direct(Word::Int(n))) => Some(DebugInfo::Word(*n)),
            Some(DebugRef::Direct(Word::DataAddr(name, addend))) => match names.get(name) {
                Some(Ref::Data(d)) => Some(DebugInfo::Data(*d, *addend)),
                _ => return Err(format!("func {}: debug: unknown data {name}", f.name)),
            },
            Some(DebugRef::Direct(Word::FuncAddr(_))) => {
                return Err(format!("func {}: debug: not an object", f.name));
            }
            Some(DebugRef::Indirect(name, off)) => match names.get(name) {
                Some(Ref::Data(d)) => Some(DebugInfo::Indirect(*d, *off)),
                _ => return Err(format!("func {}: debug-ref: unknown data {name}", f.name)),
            },
        };
        let sites = encode_debug_sites(ctx, locs, slots)?;
        if info.is_some() || !sites.is_empty() {
            debug.push(FuncDebug {
                func: id,
                len: code.code_buffer().len() as u32,
                info,
                sites,
            });
        }
    }
    let mut ctx = module.make_context();

    // Trampolines for unwinding runtime functions.
    for f in &kir.import_funcs {
        if !f.unwinds {
            continue;
        }
        let tid = imports.trampolines[f.name.as_str()];
        let Ref::Func(target) = names[&f.name] else {
            unreachable!()
        };
        ctx.func.signature = word_signature(CallConv::Tail, f.params, f.returns);
        {
            let mut b = FunctionBuilder::new(&mut ctx.func, &mut fctx);
            let blk = b.create_block();
            b.append_block_params_for_function_params(blk);
            b.switch_to_block(blk);
            let mut args: Vec<Value> = b.block_params(blk).to_vec();
            args.push(b.ins().get_frame_pointer(I64));
            let fr = module.declare_func_in_func(target, b.func);
            let call = b.ins().call(fr, &args);
            if f.noreturn {
                b.ins().trap(TrapCode::user(2).unwrap());
            } else {
                let rets = b.inst_results(call).to_vec();
                b.ins().return_(&rets);
            }
            b.seal_all_blocks();
            b.finalize(module.target_config());
        }
        module.define_function(tid, &mut ctx).map_err(|e| format!("{e:?}"))?;
        module.clear_context(&mut ctx);
    }

    // Entry trampoline: System V → Lisp convention.
    ctx.func.signature = enter_sig;
    {
        let mut b = FunctionBuilder::new(&mut ctx.func, &mut fctx);
        let blk = b.create_block();
        b.append_block_params_for_function_params(blk);
        b.switch_to_block(blk);
        let p = b.block_params(blk).to_vec();
        // Record this frame as the base of the Lisp frames for the GC stack
        // walk, restoring the previous base afterwards.
        let off = kiln_rt::context::CTX_STACK_BASE_FP;
        let mf = MemFlagsData::trusted();
        let old_base = b.ins().load(I64, mf, p[0], off);
        let fp = b.ins().get_frame_pointer(I64);
        b.ins().store(mf, fp, p[0], off);
        let zero = b.ins().iconst(I64, 0);
        let mut args = vec![p[0], p[1], p[3], p[4]];
        args.extend((1..kir::REG_ARGS).map(|_| zero));
        let sigref = b.import_signature(lisp_sig.clone());
        let call = b.ins().call_indirect(sigref, p[2], &args);
        let v0 = b.inst_results(call)[0];
        b.ins().store(mf, old_base, p[0], off);
        b.ins().return_(&[v0]);
        b.seal_all_blocks();
        b.finalize(module.target_config());
    }
    module.define_function(enter, &mut ctx).map_err(|e| format!("{e:?}"))?;
    module.clear_context(&mut ctx);

    let mut inits = Vec::new();
    for name in &kir.inits {
        let Some(Ref::Data(id)) = names.get(name).copied() else {
            return Err(format!("init {name} is not a data object"));
        };
        inits.push(id);
    }
    let mut roots = Vec::new();
    for (name, index) in &kir.roots {
        let Some(Ref::Data(id)) = names.get(name).copied() else {
            return Err(format!("root: {name} is not a data object"));
        };
        roots.push((id, index * 8));
    }
    let exports = kiln_rt::EXPORTED_NAMES
        .iter()
        .filter(|n| !kir.import_data.iter().any(|d| d == *n))
        .filter_map(|n| names.get(*n).map(|r| (n.to_string(), *r)))
        .collect();
    let data = kir
        .data
        .iter()
        .filter_map(|d| match names.get(&d.name) {
            Some(Ref::Data(id)) => Some((d.name.clone(), *id)),
            _ => None,
        })
        .collect();
    Ok(Output {
        enter,
        inits,
        callsites,
        stackmaps,
        roots,
        exports,
        data,
        debug,
    })
}

/// For each call of a function (in the order of `call_locs`), the source
/// variables whose values are in stack slots during the call: (index of
/// the name, slot).
///
/// The values that are live across a call and need stack maps are in
/// stack slots there: cranelift-frontend gives each such value a slot for
/// its whole life, stores it right after its definition and lists the
/// slot in the call's stack map. The slot of a value is found from that
/// store; the value in a slot at a call is the one whose store is the
/// nearest one before the call in dominator order (a slot is reused only
/// once its value is dead, and a value live at the call is defined in a
/// dominator of the call). A value's labels come from the variables it
/// was assigned to; a block parameter that SSA construction made gets the
/// labels that all its incoming values have.
fn debug_slots(
    func: &ir::Function,
    labels: &HashMap<Value, Vec<u32>>,
    ncalls: usize,
) -> Vec<Vec<(u32, ir::StackSlot)>> {
    use cranelift_codegen::dominator_tree::DominatorTree;
    use cranelift_codegen::flowgraph::ControlFlowGraph;
    use cranelift_codegen::ir::{InstructionData, Opcode};
    let mut out = vec![Vec::new(); ncalls];
    if labels.is_empty() || ncalls == 0 {
        return out;
    }
    let dfg = &func.dfg;
    let mut lab: HashMap<Value, Vec<u32>> = HashMap::new();
    for (v, l) in labels {
        let e = lab.entry(dfg.resolve_aliases(*v)).or_default();
        e.extend(l);
        e.sort_unstable();
        e.dedup();
    }
    // Incoming values of block parameters; None for try_call results.
    let mut incoming: HashMap<(ir::Block, usize), Vec<Option<Value>>> = HashMap::new();
    for block in func.layout.blocks() {
        for inst in func.layout.block_insts(block) {
            for dest in dfg.insts[inst].branch_destination(&dfg.jump_tables, &dfg.exception_tables) {
                let target = dest.block(&dfg.value_lists);
                for (i, arg) in dest.args(&dfg.value_lists).enumerate() {
                    let v = match arg {
                        BlockArg::Value(v) => Some(dfg.resolve_aliases(v)),
                        _ => None,
                    };
                    incoming.entry((target, i)).or_default().push(v);
                }
            }
        }
    }
    // The least fixed point, which does not depend on the order.
    loop {
        let mut changed = false;
        for ((block, i), vals) in &incoming {
            let p = dfg.block_params(*block)[*i];
            if lab.contains_key(&p) {
                continue;
            }
            let Some(Some(first)) = vals.first() else { continue };
            let Some(l) = lab.get(first) else { continue };
            if vals.iter().all(|v| v.and_then(|v| lab.get(&v)) == Some(l)) {
                let l = l.clone();
                lab.insert(p, l);
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    let mut map_slots = std::collections::HashSet::new();
    for block in func.layout.blocks() {
        for inst in func.layout.block_insts(block) {
            if let Some(entries) = dfg.user_stack_map_entries(inst) {
                map_slots.extend(entries.iter().map(|e| e.slot));
            }
        }
    }
    let cfg = ControlFlowGraph::with_function(func);
    let domtree = DominatorTree::with_function(func, &cfg);
    let Some(entry) = func.layout.entry_block() else { return out };
    // Depth-first over the dominator tree, with an undo log for the
    // slot -> value map.
    let mut current: HashMap<ir::StackSlot, Value> = HashMap::new();
    enum Step {
        Enter(ir::Block),
        Undo(Vec<(ir::StackSlot, Option<Value>)>),
    }
    let mut stack = vec![Step::Enter(entry)];
    while let Some(step) = stack.pop() {
        let block = match step {
            Step::Enter(b) => b,
            Step::Undo(log) => {
                for (slot, old) in log.into_iter().rev() {
                    match old {
                        Some(v) => current.insert(slot, v),
                        None => current.remove(&slot),
                    };
                }
                continue;
            }
        };
        let mut log = Vec::new();
        for inst in func.layout.block_insts(block) {
            let data = &dfg.insts[inst];
            if data.opcode() == Opcode::Store {
                let args = dfg.inst_args(inst);
                let addr = dfg.resolve_aliases(args[1]);
                if let Some(def) = dfg.value_def(addr).inst()
                    && let InstructionData::StackAddr { stack_slot, offset, .. } = dfg.insts[def]
                    && i64::from(offset) == 0
                    && map_slots.contains(&stack_slot)
                {
                    let old = current.insert(stack_slot, dfg.resolve_aliases(args[0]));
                    log.push((stack_slot, old));
                }
            }
            let loc = func.srcloc(inst);
            if loc.is_default() {
                continue;
            }
            let index = loc.bits() as usize - 1;
            if index >= ncalls {
                continue;
            }
            if let Some(entries) = dfg.user_stack_map_entries(inst) {
                let mut vars = Vec::new();
                for e in entries {
                    if let Some(l) = current.get(&e.slot).and_then(|v| lab.get(v)) {
                        vars.extend(l.iter().map(|&n| (n, e.slot)));
                    }
                }
                vars.sort_unstable();
                vars.dedup();
                out[index] = vars;
            }
        }
        stack.push(Step::Undo(log));
        let mut children: Vec<ir::Block> = domtree.children(block).collect();
        children.reverse();
        stack.extend(children.into_iter().map(Step::Enter));
    }
    out
}

fn put_varint(out: &mut Vec<u8>, mut n: u64) {
    loop {
        let b = (n & 0x7f) as u8;
        n >>= 7;
        if n == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

/// Encodes the call sites of a compiled function that have a source
/// location or variables, by increasing return offset (kiln_rt::debug):
/// return offset, start + 1 of the source range (0: none), its end (if
/// any), number of variables, then for each its name index and its slot's
/// offset from the SP at the call, in words.
fn encode_debug_sites(ctx: &Context, locs: &[Option<Loc>], slots: &[Vec<(u32, ir::StackSlot)>]) -> R<Vec<u8>> {
    let mut out = Vec::new();
    if locs.iter().all(Option::is_none) && slots.iter().all(Vec::is_empty) {
        return Ok(out);
    }
    let code = ctx.compiled_code().ok_or("no compiled code")?;
    let layout = code.buffer.frame_layout().ok_or("no frame layout")?;
    let base = ctx.func.params.base_srcloc();
    let srclocs = code.buffer.get_srclocs_sorted();
    let maps: HashMap<u32, std::collections::HashSet<u32>> = code
        .buffer
        .user_stack_maps()
        .iter()
        .map(|(off, _, map)| (*off, map.entries().map(|(_, o)| o).collect()))
        .collect();
    let mut rets: Vec<u32> = code.buffer.call_sites().map(|cs| cs.ret_addr).collect();
    rets.sort_unstable();
    rets.dedup();
    for ret in rets {
        // The call instruction ends at the return address.
        let i = srclocs.partition_point(|s| s.end < ret);
        let Some(s) = srclocs.get(i).filter(|s| s.start < ret && ret <= s.end) else { continue };
        let loc = if s.loc.is_rel() { s.loc.as_rel().expand(base) } else { s.loc.as_abs() };
        if loc.is_default() {
            continue;
        }
        let index = loc.bits() as usize - 1;
        let Some(call_loc) = locs.get(index) else { continue };
        let vars: Vec<(u32, u32)> = slots[index]
            .iter()
            .map(|&(n, slot)| (n, layout.stackslots[slot].offset))
            // Keep slots live at this call, including untraced float debug spills.
            .filter(|(_, off)| maps.get(&ret).is_some_and(|m| m.contains(off)))
            .collect();
        if call_loc.is_none() && vars.is_empty() {
            continue;
        }
        put_varint(&mut out, ret as u64);
        match call_loc {
            Some((start, end)) => {
                put_varint(&mut out, *start as u64 + 1);
                put_varint(&mut out, *end as u64);
            }
            None => put_varint(&mut out, 0),
        }
        put_varint(&mut out, vars.len() as u64);
        for (n, off) in vars {
            put_varint(&mut out, n as u64);
            put_varint(&mut out, (off / 8) as u64);
        }
    }
    Ok(out)
}

fn collect_callsites(ctx: &Context, func: FuncId, out: &mut Vec<CallSiteInfo>) -> R<()> {
    let code = ctx.compiled_code().ok_or("no compiled code")?;
    for cs in code.buffer.call_sites() {
        let mut handler = None;
        for h in cs.exception_handlers {
            if let cranelift_codegen::MachExceptionHandler::Default(l) = h {
                handler = Some(l.as_offset());
            }
        }
        let Some(handler_off) = handler else { continue };
        let frame_offset = cs
            .frame_offset
            .ok_or("call site with handler has no frame offset")?;
        out.push(CallSiteInfo {
            func,
            ret_off: cs.ret_addr,
            handler_off,
            frame_offset,
        });
    }
    Ok(())
}

fn collect_stackmaps(ctx: &Context, func: FuncId, out: &mut Vec<StackMapInfo>) -> R<()> {
    let code = ctx.compiled_code().ok_or("no compiled code")?;
    let call_rets: std::collections::HashSet<u32> =
        code.buffer.call_sites().map(|cs| cs.ret_addr).collect();
    for (offset, _span, map) in code.buffer.user_stack_maps() {
        // The GC finds stack maps by return address.
        if !call_rets.contains(offset) {
            return Err(format!("stack map at {offset:#x} is not at a call return address"));
        }
        // Float entries preserve debug values; only object words are GC roots.
        let offsets: Vec<u32> = map.entries()
            .filter(|(ty, _)| *ty == I64)
            .map(|(_, off)| off).collect();
        if !offsets.is_empty() {
            out.push(StackMapInfo {
                func,
                ret_off: *offset,
                offsets,
            });
        }
    }
    Ok(())
}

/// Emits the call-site table and `kiln_module_info` for AOT objects.
pub fn emit_module_info<M: Module>(module: &mut M, out: &Output) -> R<()> {
    let table = module
        .declare_data("kiln_callsites", Linkage::Local, false, false)
        .map_err(err)?;
    let mut desc = DataDescription::new();
    desc.set_align(8);
    let mut bytes = vec![0u8; out.callsites.len() * 24 + 8];
    for (i, cs) in out.callsites.iter().enumerate() {
        let off = i * 24;
        let fr = module.declare_func_in_data(cs.func, &mut desc);
        desc.write_function_addr(off as u32, fr);
        bytes[off + 8..off + 12].copy_from_slice(&cs.ret_off.to_le_bytes());
        bytes[off + 12..off + 16].copy_from_slice(&cs.handler_off.to_le_bytes());
        bytes[off + 16..off + 20].copy_from_slice(&cs.frame_offset.to_le_bytes());
    }
    desc.define(bytes.into_boxed_slice());
    module.define_data(table, &desc).map_err(err)?;

    // Stack maps: records point into one array of u32 offsets.
    let offsets_id = module
        .declare_data("kiln_stackmap_offsets", Linkage::Local, false, false)
        .map_err(err)?;
    let mut offsets: Vec<u8> = Vec::new();
    let maps = module
        .declare_data("kiln_stackmaps", Linkage::Local, false, false)
        .map_err(err)?;
    let mut mdesc = DataDescription::new();
    mdesc.set_align(8);
    let mut mbytes = vec![0u8; out.stackmaps.len() * 24 + 8];
    let ogv = module.declare_data_in_data(offsets_id, &mut mdesc);
    for (i, sm) in out.stackmaps.iter().enumerate() {
        let off = i * 24;
        let fr = module.declare_func_in_data(sm.func, &mut mdesc);
        mdesc.write_function_addr(off as u32, fr);
        mbytes[off + 8..off + 12].copy_from_slice(&sm.ret_off.to_le_bytes());
        mbytes[off + 12..off + 16].copy_from_slice(&(sm.offsets.len() as u32).to_le_bytes());
        mdesc.write_data_addr((off + 16) as u32, ogv, offsets.len() as i64);
        for o in &sm.offsets {
            offsets.extend_from_slice(&o.to_le_bytes());
        }
    }
    mdesc.define(mbytes.into_boxed_slice());
    module.define_data(maps, &mdesc).map_err(err)?;
    let mut odesc = DataDescription::new();
    odesc.set_align(8);
    offsets.extend_from_slice(&[0; 8]);
    odesc.define(offsets.into_boxed_slice());
    module.define_data(offsets_id, &odesc).map_err(err)?;

    let roots = module
        .declare_data("kiln_roots", Linkage::Local, false, false)
        .map_err(err)?;
    let mut rdesc = DataDescription::new();
    rdesc.set_align(8);
    for (i, (id, off)) in out.roots.iter().enumerate() {
        let gv = module.declare_data_in_data(*id, &mut rdesc);
        rdesc.write_data_addr((i * 8) as u32, gv, *off as i64);
    }
    rdesc.define(vec![0u8; out.roots.len() * 8 + 8].into_boxed_slice());
    module.define_data(roots, &rdesc).map_err(err)?;

    let inits = module
        .declare_data("kiln_inits", Linkage::Local, false, false)
        .map_err(err)?;
    let mut idesc = DataDescription::new();
    idesc.set_align(8);
    for (i, id) in out.inits.iter().enumerate() {
        let gv = module.declare_data_in_data(*id, &mut idesc);
        idesc.write_data_addr((i * 8) as u32, gv, kiln_rt::object::TAG_GENERAL as i64);
    }
    idesc.define(vec![0u8; out.inits.len() * 8 + 8].into_boxed_slice());
    module.define_data(inits, &idesc).map_err(err)?;

    // Exports: [name, address] pairs; the names are C strings.
    let exports = module
        .declare_data("kiln_exports", Linkage::Local, false, false)
        .map_err(err)?;
    let mut edesc = DataDescription::new();
    edesc.set_align(8);
    for (i, (name, r)) in out.exports.iter().enumerate() {
        let sid = module
            .declare_data(&format!("kiln_export_name_{i}"), Linkage::Local, false, false)
            .map_err(err)?;
        let mut sdesc = DataDescription::new();
        let mut bytes = name.as_bytes().to_vec();
        bytes.push(0);
        sdesc.define(bytes.into_boxed_slice());
        module.define_data(sid, &sdesc).map_err(err)?;
        let gv = module.declare_data_in_data(sid, &mut edesc);
        edesc.write_data_addr((i * 16) as u32, gv, 0);
        match r {
            Ref::Func(id) => {
                let fr = module.declare_func_in_data(*id, &mut edesc);
                edesc.write_function_addr((i * 16 + 8) as u32, fr);
            }
            Ref::Data(id) => {
                let gv = module.declare_data_in_data(*id, &mut edesc);
                edesc.write_data_addr((i * 16 + 8) as u32, gv, 0);
            }
        }
    }
    edesc.define(vec![0u8; out.exports.len() * 16 + 8].into_boxed_slice());
    module.define_data(exports, &edesc).map_err(err)?;

    // Debug records (kiln_rt::debug::FuncDebugRecord); their call sites
    // are in one byte array.
    let sites_id = module
        .declare_data("kiln_debug_sites", Linkage::Local, false, false)
        .map_err(err)?;
    let debug_id = module
        .declare_data("kiln_debug", Linkage::Local, false, false)
        .map_err(err)?;
    let mut ddesc = DataDescription::new();
    ddesc.set_align(8);
    let mut dbytes = vec![0u8; out.debug.len() * 48 + 8];
    let mut sites: Vec<u8> = Vec::new();
    let sgv = module.declare_data_in_data(sites_id, &mut ddesc);
    for (i, d) in out.debug.iter().enumerate() {
        let off = i * 48;
        let fr = module.declare_func_in_data(d.func, &mut ddesc);
        ddesc.write_function_addr(off as u32, fr);
        dbytes[off + 8..off + 16].copy_from_slice(&(d.len as u64).to_le_bytes());
        match d.info {
            // 0: no debug info object.
            None => {}
            Some(DebugInfo::Word(n)) => dbytes[off + 16..off + 24].copy_from_slice(&n.to_le_bytes()),
            Some(DebugInfo::Data(id, addend)) | Some(DebugInfo::Indirect(id, addend)) => {
                let gv = module.declare_data_in_data(id, &mut ddesc);
                ddesc.write_data_addr((off + 16) as u32, gv, addend);
            }
        }
        let flags: u64 = if matches!(d.info, Some(DebugInfo::Indirect(..))) { 1 } else { 0 };
        dbytes[off + 24..off + 32].copy_from_slice(&flags.to_le_bytes());
        ddesc.write_data_addr((off + 32) as u32, sgv, sites.len() as i64);
        dbytes[off + 40..off + 48].copy_from_slice(&(d.sites.len() as u64).to_le_bytes());
        sites.extend_from_slice(&d.sites);
    }
    ddesc.define(dbytes.into_boxed_slice());
    module.define_data(debug_id, &ddesc).map_err(err)?;
    let mut sdesc = DataDescription::new();
    sites.push(0);
    sdesc.define(sites.into_boxed_slice());
    module.define_data(sites_id, &sdesc).map_err(err)?;

    // Layout: kiln_rt::ModuleInfo.
    let info = module
        .declare_data(MODULE_INFO_NAME, Linkage::Export, false, false)
        .map_err(err)?;
    let mut desc = DataDescription::new();
    desc.set_align(8);
    let mut bytes = vec![0u8; 104];
    bytes[96..104].copy_from_slice(&(out.debug.len() as u64).to_le_bytes());
    let gv = module.declare_data_in_data(debug_id, &mut desc);
    desc.write_data_addr(88, gv, 0);
    bytes[80..88].copy_from_slice(&(out.exports.len() as u64).to_le_bytes());
    let gv = module.declare_data_in_data(exports, &mut desc);
    desc.write_data_addr(72, gv, 0);
    bytes[64..72].copy_from_slice(&(out.roots.len() as u64).to_le_bytes());
    let gv = module.declare_data_in_data(roots, &mut desc);
    desc.write_data_addr(56, gv, 0);
    bytes[16..24].copy_from_slice(&(out.inits.len() as u64).to_le_bytes());
    let gv = module.declare_data_in_data(inits, &mut desc);
    desc.write_data_addr(8, gv, 0);
    bytes[32..40].copy_from_slice(&(out.callsites.len() as u64).to_le_bytes());
    bytes[48..56].copy_from_slice(&(out.stackmaps.len() as u64).to_le_bytes());
    desc.define(bytes.into_boxed_slice());
    let gv = module.declare_data_in_data(maps, &mut desc);
    desc.write_data_addr(40, gv, 0);
    let fr = module.declare_func_in_data(out.enter, &mut desc);
    desc.write_function_addr(0, fr);
    let gv = module.declare_data_in_data(table, &mut desc);
    desc.write_data_addr(24, gv, 0);
    module.define_data(info, &desc).map_err(err)?;
    Ok(())
}

struct FuncLowering<'a, M: Module> {
    module: &'a mut M,
    names: &'a HashMap<String, Ref>,
    imports: &'a Imports<'a>,
    lisp_sig: &'a Signature,
    vars: HashMap<String, Variable>,
    var_kinds: HashMap<String, VarKind>,
    slots: HashMap<String, ir::StackSlot>,
    blocks: HashMap<String, ir::Block>,
    /// Hidden landing block per handler: receives the payload and jumps.
    landings: HashMap<String, ir::Block>,
    func_refs: HashMap<FuncId, ir::FuncRef>,
    data_gvs: HashMap<DataId, ir::GlobalValue>,
    lisp_sigref: Option<ir::SigRef>,
    /// Variables holding source variables -> index of the name.
    labels: HashMap<String, u32>,
    /// Values assigned to such variables -> the names' indices.
    value_labels: HashMap<Value, Vec<u32>>,
    /// Source location of each call; call I has the srcloc I + 1.
    call_locs: Vec<Option<Loc>>,
}

impl<M: Module> FuncLowering<'_, M> {
    fn build(&mut self, func: &mut ir::Function, fctx: &mut FunctionBuilderContext, f: &kir::Func) -> R<()> {
        let mut b = FunctionBuilder::new(func, fctx);
        let all_vars = kir::PREDEFINED_VARS
            .iter()
            .map(|(n, k)| (n.to_string(), *k))
            .chain(f.vars.iter().cloned());
        for (name, kind) in all_vars {
            if self.vars.contains_key(&name) {
                return Err(format!("duplicate variable {name}"));
            }
            let v = b.declare_var(if kind == VarKind::F64 { ir::types::F64 } else { I64 });
            if kind == VarKind::Obj || (kind == VarKind::F64 && self.labels.contains_key(&name)) {
                b.declare_var_needs_stack_map(v);
            }
            self.vars.insert(name.clone(), v);
            self.var_kinds.insert(name, kind);
        }
        for (name, size) in &f.slots {
            let ss = b.create_sized_stack_slot(StackSlotData::new(StackSlotKind::ExplicitSlot, *size, 3));
            self.slots.insert(name.clone(), ss);
        }
        for blk in &f.blocks {
            if self.blocks.insert(blk.name.clone(), b.create_block()).is_some() {
                return Err(format!("duplicate block {}", blk.name));
            }
        }

        let entry = b.create_block();
        b.append_block_params_for_function_params(entry);
        b.switch_to_block(entry);
        let params = b.block_params(entry).to_vec();
        for (i, name) in ["ctx", "self", "nargs", "a0", "a1", "a2"].iter().enumerate() {
            b.def_var(self.vars[*name], params[i]);
        }
        let zero = b.ins().iconst(I64, 0);
        b.def_var(self.vars["exn0"], zero);
        b.def_var(self.vars["exn1"], zero);
        b.ins().jump(self.blocks[&f.blocks[0].name], &[]);

        for blk in &f.blocks {
            b.switch_to_block(self.blocks[&blk.name]);
            let mut terminated = false;
            for s in &blk.stmts {
                if terminated {
                    return Err(format!("block {}: statement after terminator", blk.name));
                }
                terminated = self.stmt(&mut b, s)?;
            }
            if !terminated {
                return Err(format!("block {} does not end with a terminator", blk.name));
            }
        }
        // Landing blocks: bind the exception payload, then enter the handler.
        // In the order they were made: the order in which blocks are filled
        // decides the SSA values and so the machine code, which must not
        // depend on the hash map's order (the same KIR, the same object).
        let mut landings: Vec<(String, ir::Block)> =
            self.landings.iter().map(|(h, l)| (h.clone(), *l)).collect();
        landings.sort_by_key(|&(_, l)| l);
        for (h, l) in landings {
            b.switch_to_block(l);
            let p = b.block_params(l).to_vec();
            b.def_var(self.vars["exn0"], p[0]);
            b.def_var(self.vars["exn1"], p[1]);
            b.ins().jump(self.blocks[&h], &[]);
        }
        b.seal_all_blocks();
        b.finalize(self.module.target_config());
        Ok(())
    }

    /// Assigns `val` to the variable `name`.
    fn def(&mut self, b: &mut FunctionBuilder, name: &str, val: Value) -> R<()> {
        let val = if self.var_kinds.get(name) == Some(&VarKind::F64) {
            b.ins().bitcast(ir::types::F64, MemFlagsData::new(), val)
        } else { val };
        b.def_var(self.var(name)?, val);
        if let Some(&n) = self.labels.get(name) {
            self.value_labels.entry(val).or_default().push(n);
        }
        Ok(())
    }

    /// Marks the instructions emitted until `end_call` as call number
    /// `call_locs.len()`, at `loc`.
    fn begin_call(&mut self, b: &mut FunctionBuilder, loc: Option<Loc>) {
        self.call_locs.push(loc);
        b.set_srcloc(ir::SourceLoc::new(self.call_locs.len() as u32));
    }

    fn end_call(&mut self, b: &mut FunctionBuilder) {
        b.set_srcloc(ir::SourceLoc::default());
    }

    fn var(&self, name: &str) -> R<Variable> {
        self.vars
            .get(name)
            .copied()
            .ok_or_else(|| format!("unknown variable {name}"))
    }

    fn block(&self, name: &str) -> R<ir::Block> {
        self.blocks
            .get(name)
            .copied()
            .ok_or_else(|| format!("unknown block {name}"))
    }

    fn landing(&mut self, b: &mut FunctionBuilder, handler: &str) -> R<ir::Block> {
        if let Some(l) = self.landings.get(handler) {
            return Ok(*l);
        }
        self.block(handler)?;
        let l = b.create_block();
        b.append_block_param(l, I64);
        b.append_block_param(l, I64);
        self.landings.insert(handler.to_string(), l);
        Ok(l)
    }

    fn func_ref(&mut self, b: &mut FunctionBuilder, id: FuncId) -> ir::FuncRef {
        *self
            .func_refs
            .entry(id)
            .or_insert_with(|| self.module.declare_func_in_func(id, b.func))
    }

    /// Emits a call. With a handler, emits `try_call` whose normal edge goes
    /// to a fresh continuation block; returns the result values.
    fn emit_call(
        &mut self,
        b: &mut FunctionBuilder,
        callee: Callee,
        args: &[Value],
        nrets: usize,
        handler: Option<&str>,
    ) -> R<Vec<Value>> {
        let Some(h) = handler else {
            let call = match callee {
                Callee::Direct(fr) => b.ins().call(fr, args),
                Callee::Indirect(sig, v) => b.ins().call_indirect(sig, v, args),
            };
            return Ok(b.inst_results(call).to_vec());
        };
        let landing = self.landing(b, h)?;
        let cont = b.create_block();
        let rets: Vec<Value> = (0..nrets).map(|_| b.append_block_param(cont, I64)).collect();
        let ret_args: Vec<BlockArg> = (0..nrets as u32).map(BlockArg::TryCallRet).collect();
        let normal = BlockCall::new(cont, ret_args, &mut b.func.dfg.value_lists);
        let exn = BlockCall::new(
            landing,
            [BlockArg::TryCallExn(0), BlockArg::TryCallExn(1)],
            &mut b.func.dfg.value_lists,
        );
        let sig = match callee {
            Callee::Direct(fr) => b.func.dfg.ext_funcs[fr].signature,
            Callee::Indirect(sig, _) => sig,
        };
        let et = b.func.dfg.exception_tables.push(ExceptionTableData::new(
            sig,
            normal,
            [ExceptionTableItem::Default(exn)],
        ));
        match callee {
            Callee::Direct(fr) => b.ins().try_call(fr, args, et),
            Callee::Indirect(_, v) => b.ins().try_call_indirect(v, args, et),
        };
        b.switch_to_block(cont);
        Ok(rets)
    }

    /// Lowers one statement; returns true if it is a terminator.
    fn stmt(&mut self, b: &mut FunctionBuilder, s: &Stmt) -> R<bool> {
        match s {
            Stmt::Set(v, e) => {
                let val = self.expr(b, e)?;
                self.def(b, v, val)?;
            }
            Stmt::Store(a, off, v) => {
                let addr = self.expr(b, a)?;
                let val = self.expr(b, v)?;
                let mf = trusted(b);
                b.ins().store(mf, val, addr, *off);
            }
            Stmt::Store32(a, off, v) => {
                let addr = self.expr(b, a)?;
                let val = self.expr(b, v)?;
                let mf = trusted(b);
                b.ins().istore32(mf, val, addr, *off);
            }
            Stmt::Jump(t) => {
                b.ins().jump(self.block(t)?, &[]);
                return Ok(true);
            }
            Stmt::Br(c, t, e) => {
                let cond = self.cond(b, c)?;
                b.ins().brif(cond, self.block(t)?, &[], self.block(e)?, &[]);
                return Ok(true);
            }
            Stmt::Switch(expr, default, entries) => {
                let value = self.expr(b, expr)?;
                let mut switch = Switch::new();
                for (key, target) in entries {
                    switch.set_entry(*key as u64 as u128, self.block(target)?);
                }
                switch.emit(b, value, self.block(default)?);
                return Ok(true);
            }
            Stmt::Return(v0, nv) => {
                let v0 = self.expr(b, v0)?;
                let nv = self.expr(b, nv)?;
                b.ins().return_(&[v0, nv]);
                return Ok(true);
            }
            Stmt::CallLisp {
                v0,
                nv,
                entry,
                args,
                handler,
                loc,
            } => {
                let callee = self.expr(b, entry)?;
                let mut vals = args
                    .iter()
                    .map(|a| self.expr(b, a))
                    .collect::<R<Vec<_>>>()?;
                while vals.len() < 3 + kir::REG_ARGS {
                    vals.push(b.ins().iconst(I64, 0));
                }
                let sig = *self
                    .lisp_sigref
                    .get_or_insert_with(|| b.import_signature(self.lisp_sig.clone()));
                self.begin_call(b, *loc);
                let rets = self.emit_call(b, Callee::Indirect(sig, callee), &vals, 2, handler.as_deref())?;
                self.end_call(b);
                self.def(b, v0, rets[0])?;
                self.def(b, nv, rets[1])?;
            }
            Stmt::TailCallLisp { entry, args } => {
                let callee = self.expr(b, entry)?;
                let mut vals = args
                    .iter()
                    .map(|a| self.expr(b, a))
                    .collect::<R<Vec<_>>>()?;
                while vals.len() < 3 + kir::REG_ARGS {
                    vals.push(b.ins().iconst(I64, 0));
                }
                let sig = *self
                    .lisp_sigref
                    .get_or_insert_with(|| b.import_signature(self.lisp_sig.clone()));
                b.ins().return_call_indirect(sig, callee, &vals);
                return Ok(true);
            }
            Stmt::CallRt {
                name,
                results,
                args,
                handler,
                loc,
            } => {
                let imp = *self
                    .imports
                    .by_name
                    .get(name.as_str())
                    .ok_or_else(|| format!("call-rt: {name} is not an imported function"))?;
                if args.len() != imp.params || results.len() > imp.returns {
                    return Err(format!("call-rt {name}: arity mismatch"));
                }
                let vals = args.iter().map(|a| self.expr(b, a)).collect::<R<Vec<_>>>()?;
                let (id, handler) = if imp.unwinds {
                    (self.imports.trampolines[name.as_str()], handler.as_deref())
                } else {
                    let Ref::Func(id) = self.names[name] else { unreachable!() };
                    (id, None)
                };
                let fr = self.func_ref(b, id);
                self.begin_call(b, *loc);
                let rets = self.emit_call(b, Callee::Direct(fr), &vals, imp.returns, handler)?;
                self.end_call(b);
                for (r, v) in results.iter().zip(rets) {
                    self.def(b, r, v)?;
                }
            }
            Stmt::Ovf {
                op,
                result,
                overflow,
                a,
                b: bb,
            } => {
                let x = self.expr(b, a)?;
                let y = self.expr(b, bb)?;
                let (r, of) = match op {
                    OvfOp::Add => b.ins().sadd_overflow(x, y),
                    OvfOp::Sub => b.ins().ssub_overflow(x, y),
                    OvfOp::Mul => b.ins().smul_overflow(x, y),
                };
                let of = b.ins().uextend(I64, of);
                self.def(b, result, r)?;
                self.def(b, overflow, of)?;
            }
            Stmt::Trap => {
                b.ins().trap(TrapCode::user(1).unwrap());
                return Ok(true);
            }
        }
        Ok(false)
    }

    /// Lowers a branch condition, using an `icmp` directly when possible.
    fn cond(&mut self, b: &mut FunctionBuilder, e: &Expr) -> R<Value> {
        if let Expr::Cmp(op, x, y) = e {
            return self.icmp(b, *op, x, y);
        }
        self.expr(b, e)
    }

    fn icmp(&mut self, b: &mut FunctionBuilder, op: CmpOp, x: &Expr, y: &Expr) -> R<Value> {
        let x = self.expr(b, x)?;
        let y = self.expr(b, y)?;
        let cc = match op {
            CmpOp::Eq => IntCC::Equal,
            CmpOp::Ne => IntCC::NotEqual,
            CmpOp::Lt => IntCC::SignedLessThan,
            CmpOp::Le => IntCC::SignedLessThanOrEqual,
            CmpOp::Gt => IntCC::SignedGreaterThan,
            CmpOp::Ge => IntCC::SignedGreaterThanOrEqual,
        };
        Ok(b.ins().icmp(cc, x, y))
    }

    fn expr(&mut self, b: &mut FunctionBuilder, e: &Expr) -> R<Value> {
        Ok(match e {
            Expr::Int(n) => b.ins().iconst(I64, *n),
            Expr::Var(v) => {
                let value = b.use_var(self.var(v)?);
                if b.func.dfg.value_type(value) == ir::types::F64 {
                    b.ins().bitcast(I64, MemFlagsData::new(), value)
                } else { value }
            },
            Expr::Bin(op, x, y) => {
                let x = self.expr(b, x)?;
                let y = self.expr(b, y)?;
                match op {
                    BinOp::Add => b.ins().iadd(x, y),
                    BinOp::Sub => b.ins().isub(x, y),
                    BinOp::Mul => b.ins().imul(x, y),
                    BinOp::And => b.ins().band(x, y),
                    BinOp::Or => b.ins().bor(x, y),
                    BinOp::Xor => b.ins().bxor(x, y),
                    BinOp::Sdiv => b.ins().sdiv(x, y),
                    BinOp::Srem => b.ins().srem(x, y),
                    BinOp::Shlv => b.ins().ishl(x, y),
                    BinOp::Sarv => b.ins().sshr(x, y),
                    BinOp::F64Add | BinOp::F64Sub | BinOp::F64Mul | BinOp::F64Div => {
                        let x = b.ins().bitcast(ir::types::F64, MemFlagsData::new(), x);
                        let y = b.ins().bitcast(ir::types::F64, MemFlagsData::new(), y);
                        let result = match op {
                            BinOp::F64Add => b.ins().fadd(x, y),
                            BinOp::F64Sub => b.ins().fsub(x, y),
                            BinOp::F64Mul => b.ins().fmul(x, y),
                            BinOp::F64Div => b.ins().fdiv(x, y),
                            _ => unreachable!(),
                        };
                        b.ins().bitcast(I64, MemFlagsData::new(), result)
                    }
                }
            }
            Expr::Shift(op, x, n) => {
                let x = self.expr(b, x)?;
                match op {
                    ShiftOp::Shl => b.ins().ishl_imm_s(x, *n),
                    ShiftOp::Sar => b.ins().sshr_imm_s(x, *n),
                    ShiftOp::Shr => b.ins().ushr_imm_s(x, *n),
                }
            }
            Expr::Cmp(op, x, y) => {
                let c = self.icmp(b, *op, x, y)?;
                b.ins().uextend(I64, c)
            }
            Expr::Load(a, off) => {
                let a = self.expr(b, a)?;
                let mf = trusted(b);
                b.ins().load(I64, mf, a, *off)
            }
            Expr::Load32(a, off) => {
                let a = self.expr(b, a)?;
                let mf = trusted(b);
                b.ins().uload32(mf, a, *off)
            }
            Expr::Addr(name, addend) => {
                let base = match self.names.get(name) {
                    Some(Ref::Func(id)) => {
                        let fr = self.func_ref(b, *id);
                        b.ins().func_addr(I64, fr)
                    }
                    Some(Ref::Data(id)) => {
                        let id = *id;
                        let gv = *self
                            .data_gvs
                            .entry(id)
                            .or_insert_with(|| self.module.declare_data_in_func(id, b.func));
                        b.ins().symbol_value(I64, gv)
                    }
                    None => return Err(format!("addr: unknown symbol {name}")),
                };
                if *addend != 0 {
                    b.ins().iadd_imm_s(base, *addend)
                } else {
                    base
                }
            }
            Expr::Fp => b.ins().get_frame_pointer(I64),
            Expr::Slot(s) => {
                let ss = *self
                    .slots
                    .get(s)
                    .ok_or_else(|| format!("unknown slot {s}"))?;
                b.ins().stack_addr(I64, ss, 0)
            }
            Expr::Select(c, x, y) => {
                let c = self.cond(b, c)?;
                let x = self.expr(b, x)?;
                let y = self.expr(b, y)?;
                b.ins().select(c, x, y)
            }
        })
    }
}

fn trusted(_b: &mut FunctionBuilder) -> MemFlagsData {
    MemFlagsData::trusted()
}

#[derive(Clone, Copy)]
enum Callee {
    Direct(ir::FuncRef),
    Indirect(ir::SigRef, Value),
}

/// Compiles FUNCS to machine code on all available cores. The results
/// keep the order of FUNCS.
fn compile_parallel(
    isa: &dyn cranelift_codegen::isa::TargetIsa,
    funcs: Vec<ir::Function>,
    kfuncs: &[kir::Func],
) -> R<Vec<Context>> {
    let n = funcs.len();
    // KILN_CG_THREADS overrides the number of threads.
    let threads = std::env::var("KILN_CG_THREADS")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or_else(|| std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1))
        .clamp(1, n.div_ceil(16).max(1));
    if threads == 1 {
        // Small modules (code compiled into a running image): no threads.
        return funcs
            .into_iter()
            .zip(kfuncs)
            .map(|(f, kf)| {
                let mut ctx = Context::for_function(f);
                ctx.compile(isa, &mut Default::default())
                    .map_err(|e| format!("func {}: {e:?}", kf.name))?;
                Ok(ctx)
            })
            .collect();
    }
    let queue: std::sync::Mutex<Vec<Option<Context>>> =
        std::sync::Mutex::new(funcs.into_iter().map(|f| Some(Context::for_function(f))).collect());
    let next = std::sync::atomic::AtomicUsize::new(0);
    let chunk = 16;
    let results: Vec<R<Vec<(usize, Context)>>> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..threads)
            .map(|_| {
                let queue = &queue;
                let next = &next;
                scope.spawn(move || -> R<Vec<(usize, Context)>> {
                    let mut done = Vec::new();
                    loop {
                        let start = next.fetch_add(chunk, std::sync::atomic::Ordering::Relaxed);
                        if start >= n {
                            break;
                        }
                        let end = (start + chunk).min(n);
                        let mut batch: Vec<(usize, Context)> = {
                            let mut q = queue.lock().unwrap();
                            (start..end).map(|i| (i, q[i].take().unwrap())).collect()
                        };
                        for (i, ctx) in &mut batch {
                            ctx.compile(isa, &mut Default::default())
                                .map_err(|e| format!("func {}: {e:?}", kfuncs[*i].name))?;
                        }
                        done.extend(batch);
                    }
                    Ok(done)
                })
            })
            .collect();
        handles.into_iter().map(|h| h.join().unwrap()).collect()
    });
    let mut out: Vec<Option<Context>> = (0..n).map(|_| None).collect();
    for r in results {
        for (i, ctx) in r? {
            out[i] = Some(ctx);
        }
    }
    Ok(out.into_iter().map(|c| c.unwrap()).collect())
}
