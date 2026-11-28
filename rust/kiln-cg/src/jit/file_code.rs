//! Prepare a batch of file initializers before their literal objects exist.
use super::recorded_code::CodeTemplate;
use super::{
    CompilationError, CompilationStage, Memory, Prepared, compilation_result, prepare,
    validate_literal_bindings,
};
use crate::{codegen::Options, kir, lir, packet};
use kiln_rt::context::Context;
use kiln_rt::object::{
    HASH_SHIFT, KIND_BYTE_PACKET, KIND_MASK, KIND_SIMPLE_VECTOR, TAG_GENERAL, TAG_MASK,
    fixnum_value, header, header_length, is_fixnum, is_general, nil, untag,
};
use std::borrow::Cow;
use std::sync::{Arc, Mutex};

const CACHE_BYTES: usize = 8 * 1024 * 1024;

struct CachedFileCode {
    packets: Vec<Vec<u8>>,
    template: CodeTemplate,
    literal_counts: Arc<[usize]>,
}

// The latest small batch can be reloaded into fresh code and literal slots.
static CACHE: Mutex<Option<Arc<CachedFileCode>>> = Mutex::new(None);

fn vector(word: u64) -> Result<(usize, *mut u64), String> {
    if !is_general(word) || unsafe { header(word) } & KIND_MASK != KIND_SIMPLE_VECTOR {
        return Err("expected a simple vector".into());
    }
    Ok((
        header_length(unsafe { header(word) }),
        (untag(word) + 8) as *mut u64,
    ))
}

// Packet objects remain in the caller's roots. The caller holds this borrow
// only within synchronous preparation, before any diagnostic can safepoint.
unsafe fn packet_bytes(word: &u64) -> Result<Cow<'_, [u8]>, String> {
    if !is_general(*word) {
        return Err("expected packet octets".into());
    }
    let header = unsafe { header(*word) };
    let length = header_length(header);
    if length > packet::schema::MAX_BYTES as usize {
        return Err("file code packet is too large".into());
    }
    let data = untag(*word) + 8;
    match header & KIND_MASK {
        KIND_BYTE_PACKET => Ok(Cow::Borrowed(unsafe {
            std::slice::from_raw_parts(data as *const u8, length)
        })),
        KIND_SIMPLE_VECTOR => {
            let words = unsafe { std::slice::from_raw_parts(data as *const u64, length) };
            let bytes = words
                .iter()
                .map(|&word| {
                    if !is_fixnum(word) {
                        return Err("file code packet contains a non-octet".into());
                    }
                    u8::try_from(fixnum_value(word))
                        .map_err(|_| "file code packet contains a non-octet".into())
                })
                .collect::<Result<Vec<_>, String>>()?;
            Ok(Cow::Owned(bytes))
        }
        _ => Err("expected packet octets".into()),
    }
}

fn eq(lhs: kir::Expr, rhs: i64) -> kir::Expr {
    use kir::{CmpOp, Expr};
    Expr::Cmp(CmpOp::Eq, Box::new(lhs), Box::new(Expr::Int(rhs)))
}

fn and(lhs: kir::Expr, rhs: u64) -> kir::Expr {
    use kir::{BinOp, Expr};
    Expr::Bin(BinOp::And, Box::new(lhs), Box::new(Expr::Int(rhs as i64)))
}

fn add_binder(
    module: &mut kir::Module,
    ordinal: usize,
    table: &str,
    count: usize,
) -> Result<(), String> {
    use kir::{Block, Data, DataContents, Expr, Func, Stmt, Word};

    let init = module.inits.pop().ok_or("missing file initializer")?;
    let name = format!("__kiln_file_bind_{ordinal}");
    let function_object = format!("{name}_object");
    let (vars, mut blocks, check_args, _) =
        lir::poll::expand("poll", "entry".into(), vec![], true, true, None)?;
    let arg = Expr::Var("a0".into());
    blocks.push(Block {
        name: check_args,
        stmts: vec![Stmt::Br(
            eq(Expr::Var("nargs".into()), 1),
            "tag".into(),
            "invalid".into(),
        )],
    });
    blocks.push(Block {
        name: "tag".into(),
        stmts: vec![Stmt::Br(
            eq(and(arg.clone(), TAG_MASK), TAG_GENERAL as i64),
            "header".into(),
            "invalid".into(),
        )],
    });
    let head = Expr::Load(Box::new(arg.clone()), -(TAG_GENERAL as i32));
    let expected = KIND_SIMPLE_VECTOR | ((count as u64) << kiln_rt::object::LENGTH_SHIFT);
    blocks.push(Block {
        name: "header".into(),
        stmts: vec![Stmt::Br(
            eq(and(head, (1 << HASH_SHIFT) - 1), expected as i64),
            "copy".into(),
            "invalid".into(),
        )],
    });
    let literal = |index| {
        Ok::<_, String>(Expr::Load(
            Box::new(arg.clone()),
            lir::cells::offset(index)? + 8 - TAG_GENERAL as i32,
        ))
    };
    let mut stores = Vec::new();
    for index in 0..count {
        stores.push(lir::cells::store(table.into(), index, literal(index)?)?);
    }
    for (data, index, source) in std::mem::take(&mut module.literal_patches) {
        stores.push(lir::cells::store(data, index as usize, literal(source)?)?);
    }
    stores.push(Stmt::Return(
        Expr::Addr(init, TAG_GENERAL as i64),
        Expr::Int(1),
    ));
    blocks.push(Block {
        name: "copy".into(),
        stmts: stores,
    });
    blocks.push(Block {
        name: "invalid".into(),
        stmts: vec![Stmt::Trap],
    });
    module.funcs.push(Func {
        name: name.clone(),
        vars,
        labels: vec![],
        slots: vec![],
        blocks,
        block_entries: vec![],
        cold_blocks: vec![],
        debug: None,
    });
    module.data.push(Data {
        name: function_object.clone(),
        contents: DataContents::Words(vec![
            Word::Int(kiln_rt::object::KIND_FUNCTION as i64),
            Word::FuncAddr(name),
        ]),
    });
    module.inits.push(function_object);
    lir::poll::provide_retry(module)
}

/// Prepare code and fill the caller's result vector. Only diagnostic
/// construction can safepoint, after all request memory borrows expire.
#[unsafe(no_mangle)]
pub(crate) unsafe extern "C" fn kiln_rt_prepare_file_code(
    ctx: *mut Context,
    packets: u64,
    entries: u64,
    fp: usize,
) -> u64 {
    unsafe { compilation_result(ctx, fp, prepare_file_code(packets, entries)) }
}

fn prepare_file_code(packets: u64, entries: u64) -> Result<u64, CompilationError> {
    let request = |e| CompilationError::new(CompilationStage::Request, e);
    let (count, packets) = vector(packets).map_err(request)?;
    let (entry_count, entries) = vector(entries).map_err(request)?;
    if count.checked_mul(2) != Some(entry_count) || packets == entries {
        return Err(request("file code result vector has the wrong size".into()));
    }
    if count == 0 {
        return Ok(nil());
    }
    let packet_words = unsafe { std::slice::from_raw_parts(packets, count) };
    let bytes = packet_words
        .iter()
        .map(|word| unsafe { packet_bytes(word) }.map_err(request))
        .collect::<Result<Vec<_>, _>>()?;
    let (prepared, literal_counts) = file_code(bytes)?;
    if std::env::var_os("KILN_PERF_MAP").is_some() {
        super::append_perf_map(&prepared.module);
    }
    let loaded = prepared.publish();
    for (index, (binder, &count)) in loaded
        .inits()
        .into_iter()
        .zip(literal_counts.iter())
        .enumerate()
    {
        unsafe {
            entries.add(index * 2).write(binder);
            entries.add(index * 2 + 1).write((count as u64) << 1);
        }
    }
    std::mem::forget(loaded);
    Ok(nil())
}

fn file_code(packets: Vec<Cow<'_, [u8]>>) -> Result<(Prepared, Arc<[usize]>), CompilationError> {
    let request = |e| CompilationError::new(CompilationStage::Request, e);
    let program = |e| CompilationError::new(CompilationStage::Program, e);
    let install = |e| CompilationError::new(CompilationStage::Install, e);
    let cached = {
        let cache = CACHE.lock().unwrap();
        cache
            .as_ref()
            .filter(|entry| {
                entry
                    .packets
                    .iter()
                    .map(Vec::as_slice)
                    .eq(packets.iter().map(Cow::as_ref))
            })
            .cloned()
    };
    if let Some(entry) = cached {
        return Ok((
            entry.template.prepare().map_err(install)?,
            entry.literal_counts.clone(),
        ));
    }
    let mut modules = Vec::with_capacity(packets.len());
    let mut literal_counts = Vec::with_capacity(packets.len());
    for (ordinal, bytes) in packets.iter().enumerate() {
        let packet = packet::validate(bytes).map_err(request)?;
        if packet.language != packet::schema::LIR_PAYLOAD {
            return Err(request("file code requires production LIR".into()));
        }
        let source = lir::program::parse_packet(packet).map_err(program)?;
        let verified = source.verify().map_err(program)?;
        let table = format!("__kiln_file_literals_{ordinal}");
        let mut module = verified.lower_with_literal_table(&table).map_err(program)?;
        validate_literal_bindings(&module, &table, source.literals).map_err(program)?;
        add_binder(&mut module, ordinal, &table, source.literals).map_err(program)?;
        modules.push(module);
        literal_counts.push(source.literals);
    }
    let merged = kir::merge(modules).map_err(program)?;
    let options = Options { dump_clif: false };
    let literal_counts: Arc<[usize]> = literal_counts.into();
    let packet_bytes = packets.iter().map(|packet| packet.len()).sum::<usize>();
    if packet_bytes > CACHE_BYTES {
        let prepared = prepare(&merged, &options, Memory::Shared).map_err(install)?;
        return Ok((prepared, literal_counts));
    }
    let (prepared, template) = CodeTemplate::compile(&merged).map_err(install)?;
    if packet_bytes + template.payload_bytes() <= CACHE_BYTES {
        *CACHE.lock().unwrap() = Some(Arc::new(CachedFileCode {
            packets: packets.into_iter().map(Cow::into_owned).collect(),
            template,
            literal_counts: literal_counts.clone(),
        }));
    }
    Ok((prepared, literal_counts))
}
