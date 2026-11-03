//! MMTk binding. See docs/07-m1-gc.md.
//!
//! - Every object starts with a header word (see object.rs). MMTk object
//!   references are header addresses; the forwarding pointer overwrites the
//!   header, the forwarding and mark bits live in side metadata.
//! - Slots hold tagged values. `KilnSlot` strips the tag on load, keeps it on
//!   store, and reports nothing for fixnums or static objects.
//! - Roots: the Lisp frames of each mutator's stack, found with the stack
//!   maps emitted by kiln-cg, plus the Lisp objects in dynamic-environment
//!   entries.
//! - M1 has a single mutator. A collection only starts inside that mutator's
//!   allocation or explicit-collection request, so the mutator is already at a
//!   safepoint when MMTk stops it.

use crate::context::Context;
use crate::object::{self, KIND_CONS, KIND_FUNCTION, KIND_MASK, KIND_SIMPLE_VECTOR, LENGTH_SHIFT};
use mmtk::util::copy::{CopySemantics, GCWorkerCopyContext};
use mmtk::util::opaque_pointer::{OpaquePointer, VMMutatorThread, VMThread, VMWorkerThread};
use mmtk::util::{Address, ObjectReference};
use mmtk::vm::slot::{Slot, UnimplementedMemorySlice};
use mmtk::vm::{
    ActivePlan, Collection, GCThreadContext, ObjectModel, ReferenceGlue, RootsWorkFactory,
    Scanning, SlotVisitor, VMBinding, VMGlobalLogBitSpec, VMLocalForwardingBitsSpec,
    VMLocalForwardingPointerSpec, VMLocalLOSMarkNurserySpec, VMLocalMarkBitSpec,
};
use mmtk::{AllocationSemantics, MMTK, MMTKBuilder, Mutator, memory_manager};
use std::cell::Cell;
use std::sync::{Condvar, Mutex, OnceLock, RwLock};

#[derive(Default)]
pub struct Kiln;

pub type KilnMutator = Mutator<Kiln>;

impl VMBinding for Kiln {
    type VMObjectModel = KilnObjectModel;
    type VMScanning = KilnScanning;
    type VMCollection = KilnCollection;
    type VMActivePlan = KilnActivePlan;
    type VMReferenceGlue = KilnReferenceGlue;
    type VMSlot = KilnSlot;
    type VMMemorySlice = UnimplementedMemorySlice<KilnSlot>;
}

static MMTK_INSTANCE: OnceLock<Box<MMTK<Kiln>>> = OnceLock::new();

fn mmtk() -> &'static MMTK<Kiln> {
    MMTK_INSTANCE.get_or_init(|| {
        let mut builder = MMTKBuilder::new();
        // Defaults; MMTK_* environment variables override them.
        let defaults = [
            ("plan", "SemiSpace"),
            ("gc_trigger", "FixedHeapSize:67108864"),
            ("threads", "2"),
        ];
        for (k, v) in defaults {
            if std::env::var(format!("MMTK_{}", k.to_uppercase())).is_err() {
                assert!(builder.set_option(k, v), "bad MMTk option {k}={v}");
            }
        }
        memory_manager::mmtk_init::<Kiln>(&builder)
    })
}

static COLLECTION_INITIALIZED: OnceLock<()> = OnceLock::new();

fn tls_of(ctx: *mut Context) -> VMMutatorThread {
    VMMutatorThread(VMThread(OpaquePointer::from_address(Address::from_mut_ptr(ctx))))
}

fn ctx_of(tls: VMMutatorThread) -> *mut Context {
    tls.0.0.to_address().to_mut_ptr()
}

/// (context, mutator) addresses of all bound mutators.
static MUTATORS: Mutex<Vec<(usize, usize)>> = Mutex::new(Vec::new());

/// Binds a new MMTk mutator to `ctx`.
pub fn bind_mutator(ctx: *mut Context) -> *mut KilnMutator {
    let m = mmtk();
    COLLECTION_INITIALIZED.get_or_init(|| memory_manager::initialize_collection(m, VMThread::UNINITIALIZED));
    let mutator = Box::into_raw(memory_manager::bind_mutator(m, tls_of(ctx)));
    MUTATORS.lock().unwrap().push((ctx as usize, mutator as usize));
    mutator
}

// ---------------------------------------------------------------------------
// Stack maps

/// Stack map record as emitted by kiln-cg. Layout is part of the ABI.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct StackMapRecord {
    pub func: usize,
    pub ret_off: u32,
    pub count: u32,
    /// `count` offsets from the SP at the call site to slots holding Lisp objects.
    pub offsets: *const u32,
}

struct StackMap {
    ret_addr: usize,
    offsets: Vec<u32>,
}

static STACK_MAPS: RwLock<Vec<StackMap>> = RwLock::new(Vec::new());

pub fn register_stack_maps(records: &[StackMapRecord]) {
    let mut maps = STACK_MAPS.write().unwrap();
    for r in records {
        let offsets = unsafe { std::slice::from_raw_parts(r.offsets, r.count as usize) }.to_vec();
        maps.push(StackMap {
            ret_addr: r.func + r.ret_off as usize,
            offsets,
        });
    }
    maps.sort_by_key(|m| m.ret_addr);
}

/// Slots holding Lisp objects in the Lisp frames of `ctx`'s stack, from the
/// last safepoint up to the stack base.
///
/// Every Lisp call has all its arguments in registers, so the caller's SP at
/// a call site is the callee's frame pointer plus 16 (return address and
/// saved frame pointer).
unsafe fn stack_slots(ctx: &Context, out: &mut Vec<KilnSlot>) {
    let maps = STACK_MAPS.read().unwrap();
    unsafe {
        segment_slots(&maps, ctx.safepoint_fp, ctx.stack_base_fp, out);
        let mut seg = ctx.segments;
        while !seg.is_null() {
            segment_slots(&maps, (*seg).top_fp, (*seg).base_fp, out);
            seg = (*seg).prev;
        }
    }
    // Multiple values being saved (see Context::values_live).
    let live = (ctx.values_live as usize).min(crate::context::VALUES_MAX);
    for i in 0..live {
        out.push(KilnSlot(unsafe { Address::from_ptr(ctx.values.as_ptr().add(i)) }));
    }
    // Thread-local values of special variables.
    for i in 1..crate::special::tls_used() {
        out.push(KilnSlot(unsafe { Address::from_mut_ptr(ctx.tls.add(i)) }));
    }
    let mut e = ctx.dynenv;
    while !e.is_null() {
        unsafe {
            out.push(KilnSlot(Address::from_mut_ptr(&mut (*e).tag)));
            out.push(KilnSlot(Address::from_mut_ptr(&mut (*e).pend_value)));
            e = (*e).prev;
        }
    }
}

/// Slots of the Lisp frames between the frame `top` and the base frame `base`.
unsafe fn segment_slots(maps: &[StackMap], top: usize, base: usize, out: &mut Vec<KilnSlot>) {
    let mut fp = top;
    while fp != base {
        assert!(fp != 0, "GC stack walk ran off the stack");
        let ret = unsafe { *((fp + 8) as *const usize) };
        let sp = fp + 16;
        if let Ok(i) = maps.binary_search_by_key(&ret, |m| m.ret_addr) {
            for off in &maps[i].offsets {
                out.push(KilnSlot(unsafe { Address::from_usize(sp + *off as usize) }));
            }
        }
        fp = unsafe { *(fp as *const usize) };
    }
}

/// Addresses of static words holding Lisp values that may point into the
/// heap (symbol function and value cells), registered per module.
static STATIC_ROOTS: std::sync::RwLock<Vec<usize>> = std::sync::RwLock::new(Vec::new());

pub fn register_static_roots(addrs: &[usize]) {
    STATIC_ROOTS.write().unwrap().extend_from_slice(addrs);
}

// ---------------------------------------------------------------------------
// Slots

/// A word holding a tagged Lisp value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct KilnSlot(Address);

impl Slot for KilnSlot {
    fn load(&self) -> Option<ObjectReference> {
        let word = unsafe { self.0.load::<u64>() };
        if !object::is_pointer(word) {
            return None;
        }
        let r = ObjectReference::from_raw_address(unsafe { Address::from_usize(object::untag(word)) })?;
        memory_manager::is_in_mmtk_spaces(r).then_some(r)
    }

    fn store(&self, obj: ObjectReference) {
        let tag = unsafe { self.0.load::<u64>() } & object::TAG_MASK;
        unsafe { self.0.store::<u64>(obj.to_raw_address().as_usize() as u64 | tag) };
    }
}

// ---------------------------------------------------------------------------
// Object model

pub struct KilnObjectModel;

fn header_of(o: ObjectReference) -> u64 {
    unsafe { o.to_raw_address().load::<u64>() }
}

impl ObjectModel<Kiln> for KilnObjectModel {
    const GLOBAL_LOG_BIT_SPEC: VMGlobalLogBitSpec = VMGlobalLogBitSpec::side_first();
    const LOCAL_FORWARDING_POINTER_SPEC: VMLocalForwardingPointerSpec =
        VMLocalForwardingPointerSpec::in_header(0);
    const LOCAL_FORWARDING_BITS_SPEC: VMLocalForwardingBitsSpec =
        VMLocalForwardingBitsSpec::side_first();
    const LOCAL_MARK_BIT_SPEC: VMLocalMarkBitSpec =
        VMLocalMarkBitSpec::side_after(Self::LOCAL_FORWARDING_BITS_SPEC.as_spec());
    const LOCAL_LOS_MARK_NURSERY_SPEC: VMLocalLOSMarkNurserySpec =
        VMLocalLOSMarkNurserySpec::side_after(Self::LOCAL_MARK_BIT_SPEC.as_spec());
    const OBJECT_REF_OFFSET_LOWER_BOUND: isize = 0;

    fn copy(
        from: ObjectReference,
        semantics: CopySemantics,
        copy_context: &mut GCWorkerCopyContext<Kiln>,
    ) -> ObjectReference {
        let bytes = Self::get_current_size(from);
        let dst = copy_context.alloc_copy(from, bytes, 8, 0, semantics);
        unsafe {
            std::ptr::copy_nonoverlapping(
                from.to_raw_address().to_ptr::<u8>(),
                dst.to_mut_ptr::<u8>(),
                bytes,
            );
        }
        let to = ObjectReference::from_raw_address(dst).unwrap();
        copy_context.post_copy(to, bytes, semantics);
        to
    }

    fn copy_to(_from: ObjectReference, _to: ObjectReference, _region: Address) -> Address {
        unimplemented!("compacting plans are not supported yet")
    }

    fn get_current_size(object: ObjectReference) -> usize {
        object::object_bytes(header_of(object))
    }

    fn get_size_when_copied(object: ObjectReference) -> usize {
        Self::get_current_size(object)
    }

    fn get_align_when_copied(_object: ObjectReference) -> usize {
        8
    }

    fn get_align_offset_when_copied(_object: ObjectReference) -> usize {
        0
    }

    fn get_reference_when_copied_to(_from: ObjectReference, to: Address) -> ObjectReference {
        ObjectReference::from_raw_address(to).unwrap()
    }

    fn get_type_descriptor(_reference: ObjectReference) -> &'static [i8] {
        &[]
    }

    fn ref_to_object_start(object: ObjectReference) -> Address {
        object.to_raw_address()
    }

    fn ref_to_header(object: ObjectReference) -> Address {
        object.to_raw_address()
    }

    fn dump_object(object: ObjectReference) {
        eprintln!("object {object} header {:#x}", header_of(object));
    }
}

// ---------------------------------------------------------------------------
// Scanning

pub struct KilnScanning;

impl Scanning<Kiln> for KilnScanning {
    fn scan_roots_in_mutator_thread(
        _tls: VMWorkerThread,
        mutator: &'static mut KilnMutator,
        mut factory: impl RootsWorkFactory<KilnSlot>,
    ) {
        let ctx = unsafe { &*ctx_of(mutator.mutator_tls) };
        let mut slots = Vec::new();
        unsafe { stack_slots(ctx, &mut slots) };
        factory.create_process_roots_work(slots);
    }

    fn scan_vm_specific_roots(_tls: VMWorkerThread, mut factory: impl RootsWorkFactory<KilnSlot>) {
        let slots: Vec<KilnSlot> = STATIC_ROOTS
            .read()
            .unwrap()
            .iter()
            .map(|a| KilnSlot(unsafe { Address::from_usize(*a) }))
            .collect();
        if !slots.is_empty() {
            factory.create_process_roots_work(slots);
        }
    }

    fn scan_object<SV: SlotVisitor<KilnSlot>>(_tls: VMWorkerThread, object: ObjectReference, visitor: &mut SV) {
        let base = object.to_raw_address();
        let h = header_of(object);
        // (offset of the first Lisp field, number of fields)
        let (first, fields) = match h & KIND_MASK {
            KIND_CONS => (8, 2),
            KIND_SIMPLE_VECTOR => (8, (h >> LENGTH_SHIFT) as usize),
            // Skip the entry address; the env words are Lisp values.
            KIND_FUNCTION => (16, (h >> LENGTH_SHIFT) as usize),
            k => panic!("scan_object: unexpected kind {k} in the heap"),
        };
        for i in 0..fields {
            visitor.visit_slot(KilnSlot(base + (first + 8 * i)));
        }
    }

    fn notify_initial_thread_scan_complete(_partial_scan: bool, _tls: VMWorkerThread) {}

    fn supports_return_barrier() -> bool {
        false
    }

    fn prepare_for_roots_re_scanning() {}
}

// ---------------------------------------------------------------------------
// Collection

pub struct KilnCollection;

/// Number of completed collections.
static GC_COUNT: Mutex<u64> = Mutex::new(0);
static GC_DONE: Condvar = Condvar::new();

thread_local! {
    /// GC_COUNT as seen by this mutator before it last requested memory.
    static SEEN_GC_COUNT: Cell<u64> = const { Cell::new(0) };
}

fn note_gc_count() {
    let n = *GC_COUNT.lock().unwrap();
    SEEN_GC_COUNT.with(|c| c.set(n));
}

impl Collection<Kiln> for KilnCollection {
    fn stop_all_mutators<F>(_tls: VMWorkerThread, mut mutator_visitor: F)
    where
        F: FnMut(&'static mut KilnMutator),
    {
        // The only mutator is blocked inside its allocation request.
        for (_, m) in MUTATORS.lock().unwrap().iter() {
            mutator_visitor(unsafe { &mut *(*m as *mut KilnMutator) });
        }
    }

    fn resume_mutators(_tls: VMWorkerThread) {
        *GC_COUNT.lock().unwrap() += 1;
        GC_DONE.notify_all();
    }

    fn block_for_gc(_tls: VMMutatorThread) {
        let seen = SEEN_GC_COUNT.with(Cell::get);
        let mut n = GC_COUNT.lock().unwrap();
        while *n == seen {
            n = GC_DONE.wait(n).unwrap();
        }
        SEEN_GC_COUNT.with(|c| c.set(*n));
    }

    fn spawn_gc_thread(_tls: VMThread, ctx: GCThreadContext<Kiln>) {
        let GCThreadContext::Worker(worker) = ctx;
        std::thread::Builder::new()
            .name("mmtk-worker".into())
            .spawn(move || {
                // MMTk needs a distinct non-null TLS value per worker.
                let marker: &'static u8 = Box::leak(Box::new(0));
                let tls = VMWorkerThread(VMThread(OpaquePointer::from_address(Address::from_ref(marker))));
                memory_manager::start_worker(mmtk(), tls, worker);
            })
            .expect("failed to spawn a GC thread");
    }
}

// ---------------------------------------------------------------------------
// Active plan and reference glue

pub struct KilnActivePlan;

impl ActivePlan<Kiln> for KilnActivePlan {
    fn is_mutator(tls: VMThread) -> bool {
        let a = tls.0.to_address().as_usize();
        MUTATORS.lock().unwrap().iter().any(|(ctx, _)| *ctx == a)
    }

    fn mutator(tls: VMMutatorThread) -> &'static mut KilnMutator {
        unsafe { &mut *(*ctx_of(tls)).mutator }
    }

    fn mutators<'a>() -> Box<dyn Iterator<Item = &'a mut KilnMutator> + 'a> {
        let list: Vec<usize> = MUTATORS.lock().unwrap().iter().map(|(_, m)| *m).collect();
        Box::new(list.into_iter().map(|m| unsafe { &mut *(m as *mut KilnMutator) }))
    }

    fn number_of_mutators() -> usize {
        MUTATORS.lock().unwrap().len()
    }
}

pub struct KilnReferenceGlue;

impl ReferenceGlue<Kiln> for KilnReferenceGlue {
    type FinalizableType = ObjectReference;

    fn set_referent(_reference: ObjectReference, _referent: ObjectReference) {
        unimplemented!()
    }
    fn get_referent(_object: ObjectReference) -> Option<ObjectReference> {
        unimplemented!()
    }
    fn clear_referent(_object: ObjectReference) {
        unimplemented!()
    }
    fn enqueue_references(_references: &[ObjectReference], _tls: VMWorkerThread) {}
}

// ---------------------------------------------------------------------------
// Runtime entry points

/// Allocates an object of `bytes` bytes whose header is `header`; payload
/// words are zero (fixnum 0). Returns the untagged address. A GC safepoint:
/// called through a trampoline, `fp` is its frame pointer.
///
/// # Safety
/// Must be called by compiled code with a valid context.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_alloc(ctx: *mut Context, bytes: u64, header: u64, fp: usize) -> u64 {
    unsafe {
        (*ctx).safepoint_fp = fp;
        let mutator = &mut *(*ctx).mutator;
        note_gc_count();
        let bytes = bytes as usize;
        let addr = memory_manager::alloc(mutator, bytes, 8, 0, AllocationSemantics::Default);
        std::ptr::write_bytes(addr.to_mut_ptr::<u8>(), 0, bytes);
        addr.store::<u64>(header);
        let obj = ObjectReference::from_raw_address(addr).unwrap();
        memory_manager::post_alloc(mutator, obj, bytes, AllocationSemantics::Default);
        addr.as_usize() as u64
    }
}

/// `(%gc)`: requests a collection. Returns NIL.
///
/// # Safety
/// Must be called by compiled code with a valid context.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn kiln_rt_gc(ctx: *mut Context, fp: usize) -> u64 {
    unsafe {
        (*ctx).safepoint_fp = fp;
        note_gc_count();
        memory_manager::handle_user_collection_request(mmtk(), tls_of(ctx));
    }
    object::nil()
}

/// Number of completed collections, as a fixnum.
#[unsafe(no_mangle)]
pub extern "C" fn kiln_rt_gc_count(_ctx: *mut Context) -> u64 {
    *GC_COUNT.lock().unwrap() << 1
}
