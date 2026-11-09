//! MMTk binding.
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
use crate::object;
use mmtk::util::alloc::{BumpAllocator, BumpPointer, ImmixAllocator};
use mmtk::util::options::PlanSelector;
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
        // GC threads: one per core, at most 8 (kiln compiling its modules
        // keeps hundreds of MiB live).
        let threads = std::thread::available_parallelism()
            .map_or(2, |n| n.get().min(8))
            .to_string();
        let defaults = [
            ("plan", "SemiSpace"),
            ("gc_trigger", "FixedHeapSize:1073741824"),
            ("threads", threads.as_str()),
        ];
        for (k, v) in defaults {
            if std::env::var(format!("MMTK_{}", k.to_uppercase())).is_err() {
                assert!(builder.set_option(k, v), "bad MMTk option {k}={v}");
            }
        }
        crate::gcstats::init();
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
    let mut new: Vec<StackMap> = records
        .iter()
        .map(|r| StackMap {
            ret_addr: r.func + r.ret_off as usize,
            offsets: unsafe { std::slice::from_raw_parts(r.offsets, r.count as usize) }.to_vec(),
        })
        .collect();
    new.sort_by_key(|m| m.ret_addr);
    let mut maps = STACK_MAPS.write().unwrap();
    // As unwind::register_callsites: code loaded later usually lies above.
    let append = match (maps.last(), new.first()) {
        (Some(last), Some(first)) => last.ret_addr < first.ret_addr,
        _ => true,
    };
    maps.extend(new);
    if !append {
        maps.sort_by_key(|m| m.ret_addr);
    }
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
    let mut new = addrs.to_vec();
    new.sort_unstable();
    new.dedup();
    let mut roots = STATIC_ROOTS.write().unwrap();
    let append = match (roots.last(), new.first()) {
        (Some(last), Some(first)) => last < first,
        _ => true,
    };
    roots.extend(new);
    if !append {
        // Modules may share symbols: scan each word once.
        roots.sort_unstable();
        roots.dedup();
    }
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
        let addr = object::untag(word);
        // Static data (module data, symbols) is outside MMTk's address
        // range; a range check is much cheaper than is_in_mmtk_spaces.
        if !in_heap_range(addr) {
            return None;
        }
        ObjectReference::from_raw_address(unsafe { Address::from_usize(addr) })
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
        crate::gcstats::note_copy(from.to_raw_address().as_usize(), dst.as_usize(), bytes);
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

/// Hands root slots to MMTk in packets of at most EDGES_WORK_BUFFER_SIZE
/// slots. One worker processes a packet: it copies and then scans every
/// object the packet's slots point to. With all static roots in one packet,
/// that part of each collection ran on one worker.
fn create_roots_work(factory: &mut impl RootsWorkFactory<KilnSlot>, slots: Vec<KilnSlot>) {
    if slots.len() <= mmtk::scheduler::EDGES_WORK_BUFFER_SIZE {
        if !slots.is_empty() {
            factory.create_process_roots_work(slots);
        }
        return;
    }
    for chunk in slots.chunks(mmtk::scheduler::EDGES_WORK_BUFFER_SIZE) {
        factory.create_process_roots_work(chunk.to_vec());
    }
}

impl Scanning<Kiln> for KilnScanning {
    fn scan_roots_in_mutator_thread(
        _tls: VMWorkerThread,
        mutator: &'static mut KilnMutator,
        mut factory: impl RootsWorkFactory<KilnSlot>,
    ) {
        let ctx = unsafe { &*ctx_of(mutator.mutator_tls) };
        let mut slots = Vec::new();
        unsafe { stack_slots(ctx, &mut slots) };
        create_roots_work(&mut factory, slots);
    }

    fn scan_vm_specific_roots(_tls: VMWorkerThread, mut factory: impl RootsWorkFactory<KilnSlot>) {
        // Only the words that point into the heap: most static roots hold
        // fixnums, NIL or static symbols.
        let slots: Vec<KilnSlot> = STATIC_ROOTS
            .read()
            .unwrap()
            .iter()
            .map(|a| KilnSlot(unsafe { Address::from_usize(*a) }))
            .filter(|s| s.load().is_some())
            .collect();
        create_roots_work(&mut factory, slots);
        // Slots of the image's objects that point into the heap.
        crate::image::heap_slots(|batch| {
            factory.create_process_roots_work(
                batch.into_iter().map(|a| KilnSlot(unsafe { Address::from_usize(a) })).collect(),
            )
        });
    }

    fn scan_object<SV: SlotVisitor<KilnSlot>>(_tls: VMWorkerThread, object: ObjectReference, visitor: &mut SV) {
        let base = object.to_raw_address();
        let h = header_of(object);
        let (first, fields) = crate::image::lisp_fields(h);
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
/// Mutators waiting in `block_for_gc`; `stop_all_mutators` waits for all.
static BLOCKED_MUTATORS: Mutex<usize> = Mutex::new(0);
static MUTATORS_BLOCKED: Condvar = Condvar::new();

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
        // Every collection is requested by a mutator, which then blocks in
        // `block_for_gc`; wait until all of them are there. (MMTk starts
        // the collection as soon as it is requested, while the requesting
        // mutator is still on its way out of the allocator: it releases
        // its page reservation, and its stack is not yet still.)
        let count = MUTATORS.lock().unwrap().len();
        let mut blocked = BLOCKED_MUTATORS.lock().unwrap();
        while *blocked < count {
            blocked = MUTATORS_BLOCKED.wait(blocked).unwrap();
        }
        drop(blocked);
        if crate::gcstats::enabled() {
            let ages = matches!(*mmtk().get_options().plan, PlanSelector::SemiSpace).then(heap_range);
            crate::gcstats::gc_start(used_bytes(), ages);
        }
        for (_, m) in MUTATORS.lock().unwrap().iter() {
            mutator_visitor(unsafe { &mut *(*m as *mut KilnMutator) });
        }
    }

    fn resume_mutators(_tls: VMWorkerThread) {
        if crate::gcstats::enabled() {
            let live = memory_manager::live_bytes_in_last_gc(mmtk()).values().map(|s| s.live_bytes).sum();
            crate::gcstats::gc_end(used_bytes(), live);
        }
        *GC_COUNT.lock().unwrap() += 1;
        GC_DONE.notify_all();
    }

    fn block_for_gc(_tls: VMMutatorThread) {
        let seen = SEEN_GC_COUNT.with(Cell::get);
        // Taken before announcing that this mutator is blocked, so that the
        // collection cannot finish (and notify) before this thread waits.
        let mut n = GC_COUNT.lock().unwrap();
        crate::gcstats::mutator_blocked();
        *BLOCKED_MUTATORS.lock().unwrap() += 1;
        MUTATORS_BLOCKED.notify_all();
        while *n == seen {
            n = GC_DONE.wait(n).unwrap();
        }
        *BLOCKED_MUTATORS.lock().unwrap() -= 1;
        crate::gcstats::mutator_resumed();
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
        alloc(ctx, bytes, header)
    }
}

/// Allocates an object for runtime code. A GC safepoint: the caller must
/// have set `ctx.safepoint_fp`, and must not hold heap references across
/// the call (the GC may move objects). Returns the untagged address; the
/// payload is zeroed and the header written.
///
/// # Safety
/// `ctx` must be the current context.
pub unsafe fn alloc(ctx: *mut Context, bytes: u64, header: u64) -> u64 {
    unsafe {
        let mutator = &mut *(*ctx).mutator;
        let bytes = bytes as usize;
        // The payload is not cleared here: MMTk hands out zeroed memory.
        // Every space kiln's plans use is created with `zeroed` set, so a
        // space zeroes the pages it acquires (bump and large-object
        // allocation, and GC copies); Immix's allocator zeroes the
        // recycled lines it reuses, the free-list allocator each cell.
        //
        // Fast path: bump the default allocator's cursor (SemiSpace's copy
        // space; its post_alloc does nothing without the vo_bit feature).
        if bytes <= max_non_los_bytes() {
            let bump = bump_allocator(mutator);
            let start = (*bump).cursor.align_up(8);
            let end = start + bytes;
            if end <= (*bump).limit {
                (*bump).cursor = end;
                debug_assert_zeroed(start, bytes);
                start.store::<u64>(header);
                return start.as_usize() as u64;
            }
        }
        note_gc_count();
        let profiling = crate::profile::ALLOC_ACTIVE.load(std::sync::atomic::Ordering::Relaxed);
        if profiling {
            let bump = bump_allocator(mutator);
            crate::profile::note_alloc(ctx, (*ctx).safepoint_fp, (*bump).cursor.as_usize(), bytes);
        }
        // Large objects go to the plan's large object space.
        let semantics = if bytes > mmtk().get_plan().constraints().max_non_los_default_alloc_bytes {
            AllocationSemantics::Los
        } else {
            AllocationSemantics::Default
        };
        let addr = memory_manager::alloc(mutator, bytes, 8, 0, semantics);
        debug_assert_zeroed(addr, bytes);
        addr.store::<u64>(header);
        let obj = ObjectReference::from_raw_address(addr).unwrap();
        memory_manager::post_alloc(mutator, obj, bytes, semantics);
        if profiling {
            crate::profile::note_refill((*bump_allocator(mutator)).cursor.as_usize());
        }
        addr.as_usize() as u64
    }
}

/// Checks the first and the last word of a fresh object (all of it would
/// cost as much as the zeroing it replaces).
#[inline]
fn debug_assert_zeroed(start: Address, bytes: usize) {
    debug_assert!(
        unsafe { start.load::<u64>() == 0 && (start + (bytes - 8)).load::<u64>() == 0 },
        "MMTk returned memory that is not zeroed at {start}"
    );
}

/// Addresses of the cursor and the limit of MUTATOR's default bump
/// allocator, for the inline allocation fast path of compiled code (the
/// allocator lives as long as the mutator).
///
/// # Safety
///
/// MUTATOR must be a mutator bound by `bind_mutator`.
pub unsafe fn bump_pointer_fields(mutator: *mut KilnMutator) -> (*mut usize, *mut usize) {
    unsafe {
        let bump = bump_allocator(&mut *mutator);
        (
            &mut (*bump).cursor as *mut Address as *mut usize,
            &mut (*bump).limit as *mut Address as *mut usize,
        )
    }
}

fn max_non_los_bytes() -> usize {
    static MAX: OnceLock<usize> = OnceLock::new();
    *MAX.get_or_init(|| mmtk().get_plan().constraints().max_non_los_default_alloc_bytes)
}

thread_local! {
    /// The bump pointer of this thread's mutator's default allocator, and
    /// the mutator.
    static BUMP: Cell<(usize, *mut BumpPointer)> =
        const { Cell::new((0, std::ptr::null_mut())) };
    /// For plans whose default allocator has no bump pointer (MarkSweep):
    /// an empty buffer, so that the fast paths always fail.
    static NO_BUMP: std::cell::UnsafeCell<BumpPointer> =
        std::cell::UnsafeCell::new(BumpPointer { cursor: Address::ZERO, limit: Address::ZERO });
}

/// The bump pointer of MUTATOR's default allocator (SemiSpace's bump
/// allocator, Immix's), cached per thread. The fast paths (here and in
/// generated code, through the context's alloc_cursor and alloc_limit)
/// allocate from it; the allocator's slow path refills it.
unsafe fn bump_allocator(mutator: &mut KilnMutator) -> *mut BumpPointer {
    let key = mutator as *mut KilnMutator as usize;
    BUMP.with(|b| {
        let (m, p) = b.get();
        if m == key {
            p
        } else {
            let p = unsafe {
                match *mmtk().get_options().plan {
                    PlanSelector::Immix | PlanSelector::StickyImmix => {
                        &mut mutator
                            .allocator_impl_mut_for_semantic::<ImmixAllocator<Kiln>>(
                                AllocationSemantics::Default,
                            )
                            .bump_pointer as *mut BumpPointer
                    }
                    PlanSelector::NoGC
                    | PlanSelector::SemiSpace
                    | PlanSelector::GenCopy
                    | PlanSelector::GenImmix => {
                        &mut mutator
                            .allocator_impl_mut_for_semantic::<BumpAllocator<Kiln>>(
                                AllocationSemantics::Default,
                            )
                            .bump_pointer as *mut BumpPointer
                    }
                    _ => NO_BUMP.with(|n| n.get()),
                }
            };
            b.set((key, p));
            p
        }
    })
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

/// Bytes of MMTk's pages in use.
pub fn used_bytes() -> usize {
    memory_manager::used_bytes(mmtk())
}

/// Heap accounting in bytes, or the number of registered static root slots.
pub fn heap_statistic(which: i64) -> Option<usize> {
    match which {
        0 => Some(used_bytes()),
        1 => Some(memory_manager::free_bytes(mmtk())),
        2 => Some(memory_manager::total_bytes(mmtk())),
        3 => Some(STATIC_ROOTS.read().unwrap().len()),
        _ => None,
    }
}

/// Is the tagged heap pointer `v` an object in an MMTk space (as opposed
/// to static data, which never moves)?
pub fn in_mmtk_space(v: u64) -> bool {
    in_heap_range(object::untag(v))
}

/// The addresses of the static roots, sorted.
pub fn static_roots() -> Vec<usize> {
    STATIC_ROOTS.read().unwrap().clone()
}

/// Is ADDR in the address range of MMTk's spaces?
pub fn in_heap(addr: usize) -> bool {
    in_heap_range(addr)
}

/// Is ADDR in the address range of MMTk's spaces? All objects that MMTk
/// allocates are, and kiln's static data never is.
#[inline]
fn in_heap_range(addr: usize) -> bool {
    let (start, end) = heap_range();
    addr >= start && addr < end
}

/// The address range of MMTk's spaces.
#[inline]
fn heap_range() -> (usize, usize) {
    static RANGE: OnceLock<(usize, usize)> = OnceLock::new();
    *RANGE.get_or_init(|| {
        let layout = mmtk::util::heap::vm_layout::vm_layout();
        (layout.heap_start.as_usize(), layout.heap_end.as_usize())
    })
}
