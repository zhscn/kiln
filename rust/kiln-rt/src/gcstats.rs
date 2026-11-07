//! GC statistics (`KILN_GC_STATS`).
//!
//! `KILN_GC_STATS=1` prints a summary to standard error when the process
//! exits: the number of collections, pause times, bytes allocated, the live
//! set after each collection, and the CPU time of the GC workers against
//! that of the whole process. Any other value is a file name: one line per
//! collection is written there as well. With
//! `MMTK_COUNT_LIVE_BYTES_IN_GC=true` the live bytes are MMTk's count of the
//! objects it traced; without it, the pages in use after the collection.
//! `KILN_GC_AGES=1` in addition splits the bytes each collection copies
//! into young and old objects (SemiSpace only; it slows the collector).
//!
//! Off by default; then each hook costs one relaxed load per collection.

use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Instant;

static ON: AtomicBool = AtomicBool::new(false);

struct Record {
    /// Seconds since MMTk was initialized, when the mutator blocked.
    at: f64,
    /// Seconds the mutator was blocked.
    pause: f64,
    /// Seconds from all mutators stopped to resuming them.
    gc: f64,
    used_before: usize,
    used_after: usize,
    /// Bytes of live objects, if MMTk counted them; else 0.
    live: usize,
    /// Bytes copied of objects allocated since the previous collection, and
    /// of objects that had survived one before (SemiSpace only).
    young: usize,
    old: usize,
}

struct State {
    start: Instant,
    records: Vec<Record>,
    blocked_at: Option<Instant>,
    stopped_at: Option<Instant>,
    used_before: usize,
    pending: Option<Record>,
    path: Option<String>,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

/// Reads `KILN_GC_STATS`; called once when MMTk is initialized.
pub fn init() {
    let Ok(v) = std::env::var("KILN_GC_STATS") else { return };
    if v.is_empty() || v == "0" {
        return;
    }
    *STATE.lock().unwrap() = Some(State {
        start: Instant::now(),
        records: Vec::new(),
        blocked_at: None,
        stopped_at: None,
        used_before: 0,
        pending: None,
        path: (v != "1").then_some(v),
    });
    ON.store(true, Ordering::Relaxed);
    extern "C" fn at_exit() {
        report();
    }
    unsafe { libc::atexit(at_exit) };
}

#[inline]
fn on() -> bool {
    ON.load(Ordering::Relaxed)
}

fn with_state(f: impl FnOnce(&mut State)) {
    if on()
        && let Some(s) = STATE.lock().unwrap().as_mut()
    {
        f(s)
    }
}

/// A mutator blocks for a collection.
pub fn mutator_blocked() {
    with_state(|s| s.blocked_at = Some(Instant::now()));
}

/// The mutator resumes after a collection.
pub fn mutator_resumed() {
    with_state(|s| {
        if let (Some(b), Some(mut r)) = (s.blocked_at.take(), s.pending.take()) {
            r.at = (b - s.start).as_secs_f64();
            r.pause = b.elapsed().as_secs_f64();
            s.records.push(r);
        }
    });
}

/// All mutators are stopped; `used` is the bytes in use. `heap` is the
/// heap's address range if the plan copies every live object.
pub fn gc_start(used: usize, heap: Option<(usize, usize)>) {
    with_state(|s| {
        if let Some((start, end)) = heap
            && !AGE_ON.load(Ordering::Relaxed)
            && std::env::var_os("KILN_GC_AGES").is_some_and(|v| v == "1")
        {
            age_init(start, end);
        }
        s.stopped_at = Some(Instant::now());
        s.used_before = used;
    });
}

/// The collection is done; `used` is the bytes in use now, `live` the bytes
/// of live objects (0 if not counted).
pub fn gc_end(used: usize, live: usize) {
    with_state(|s| {
        let gc = s.stopped_at.take().map_or(0.0, |t| t.elapsed().as_secs_f64());
        let (young, old) = age_flip();
        s.pending =
            Some(Record { at: 0.0, pause: 0.0, gc, used_before: s.used_before, used_after: used, live, young, old });
    });
}

pub fn enabled() -> bool {
    on()
}

// Ages, for copying plans that move every live object (SemiSpace): a
// bitmap over the heap's address range marks the objects the last
// collection copied. The copies a collection makes are then split into
// objects allocated since the previous collection ("young": what a nursery
// collection would copy) and objects copied before ("old": what a
// generational plan would leave in place). Two bitmaps, one per semispace
// role, one bit per 8 bytes, reserved without backing.

static AGE_ON: AtomicBool = AtomicBool::new(false);
static AGE_MAPS: Mutex<Option<AgeMaps>> = Mutex::new(None);

/// Young and old bytes copied, one pair per GC worker (by a slot number
/// each worker takes once), so that workers do not contend for a counter.
#[repr(align(64))]
struct Counts {
    young: AtomicUsize,
    old: AtomicUsize,
}

const SLOTS: usize = 64;
static COUNTS: [Counts; SLOTS] =
    [const { Counts { young: AtomicUsize::new(0), old: AtomicUsize::new(0) } }; SLOTS];
static NEXT_SLOT: AtomicUsize = AtomicUsize::new(0);

thread_local! {
    static SLOT: usize = NEXT_SLOT.fetch_add(1, Ordering::Relaxed) % SLOTS;
}

#[derive(Clone, Copy)]
struct AgeMaps {
    bytes: usize,
    /// The bitmap of the objects copied by the last collection.
    cur: usize,
    /// The bitmap this collection fills.
    next: usize,
}

static AGE_CUR: AtomicUsize = AtomicUsize::new(0);
static AGE_NEXT: AtomicUsize = AtomicUsize::new(0);
static AGE_HEAP: AtomicUsize = AtomicUsize::new(0);

fn age_init(heap_start: usize, heap_end: usize) {
    let bytes = (heap_end - heap_start) / 64;
    let map = || unsafe {
        let p = libc::mmap(
            std::ptr::null_mut(),
            bytes,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_PRIVATE | libc::MAP_ANONYMOUS | libc::MAP_NORESERVE,
            -1,
            0,
        );
        assert!(p != libc::MAP_FAILED, "cannot reserve the GC age bitmaps");
        p as usize
    };
    let m = AgeMaps { bytes, cur: map(), next: map() };
    AGE_CUR.store(m.cur, Ordering::Relaxed);
    AGE_NEXT.store(m.next, Ordering::Relaxed);
    AGE_HEAP.store(heap_start, Ordering::Relaxed);
    *AGE_MAPS.lock().unwrap() = Some(m);
    AGE_ON.store(true, Ordering::Relaxed);
}

/// Called by the GC for each object it copies.
#[inline]
pub fn note_copy(from: usize, to: usize, bytes: usize) {
    if !AGE_ON.load(Ordering::Relaxed) {
        return;
    }
    let heap = AGE_HEAP.load(Ordering::Relaxed);
    let bit = |map: usize, a: usize| {
        let i = (a - heap) >> 3;
        (unsafe { &*((map + (i >> 6) * 8) as *const std::sync::atomic::AtomicU64) }, 1u64 << (i & 63))
    };
    let (w, m) = bit(AGE_CUR.load(Ordering::Relaxed), from);
    let old = w.load(Ordering::Relaxed) & m != 0;
    let (w, m) = bit(AGE_NEXT.load(Ordering::Relaxed), to);
    w.fetch_or(m, Ordering::Relaxed);
    let c = &COUNTS[SLOT.with(|s| *s)];
    let counter = if old { &c.old } else { &c.young };
    counter.store(counter.load(Ordering::Relaxed) + bytes, Ordering::Relaxed);
}

/// At the end of a collection: the bitmap just filled becomes the current
/// one; the old one is emptied. Returns the young and old bytes copied.
fn age_flip() -> (usize, usize) {
    let mut g = AGE_MAPS.lock().unwrap();
    let Some(m) = g.as_mut() else { return (0, 0) };
    unsafe { libc::madvise(m.cur as *mut libc::c_void, m.bytes, libc::MADV_DONTNEED) };
    std::mem::swap(&mut m.cur, &mut m.next);
    AGE_CUR.store(m.cur, Ordering::Relaxed);
    AGE_NEXT.store(m.next, Ordering::Relaxed);
    COUNTS.iter().fold((0, 0), |(y, o), c| {
        (y + c.young.swap(0, Ordering::Relaxed), o + c.old.swap(0, Ordering::Relaxed))
    })
}

/// CPU seconds (user + system) of this process's live threads named NAME.
fn thread_cpu(name: &str) -> f64 {
    let tick = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
    let mut total = 0u64;
    let Ok(dir) = std::fs::read_dir("/proc/self/task") else { return 0.0 };
    for e in dir.flatten() {
        let Ok(stat) = std::fs::read_to_string(e.path().join("stat")) else { continue };
        let (Some(open), Some(close)) = (stat.find('('), stat.rfind(')')) else { continue };
        if &stat[open + 1..close] != name {
            continue;
        }
        // After "(name) ": state, then fields 4.. ; utime and stime are
        // fields 14 and 15 of the line.
        let rest: Vec<&str> = stat[close + 2..].split(' ').collect();
        let utime: u64 = rest.get(11).and_then(|s| s.parse().ok()).unwrap_or(0);
        let stime: u64 = rest.get(12).and_then(|s| s.parse().ok()).unwrap_or(0);
        total += utime + stime;
    }
    total as f64 / tick
}

fn process_cpu() -> f64 {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    let tv = |t: libc::timeval| t.tv_sec as f64 + t.tv_usec as f64 * 1e-6;
    tv(ru.ru_utime) + tv(ru.ru_stime)
}

const MIB: f64 = (1 << 20) as f64;

/// Prints the summary (and writes the per-collection file).
pub fn report() {
    if !ON.swap(false, Ordering::Relaxed) {
        return;
    }
    let guard = STATE.lock().unwrap();
    let Some(s) = guard.as_ref() else { return };
    let rs = &s.records;
    let wall = s.start.elapsed().as_secs_f64();
    let used_now = crate::gc::used_bytes();
    // Bytes allocated: what each collection found in use beyond what the
    // previous one left (page granularity).
    let mut allocated = 0usize;
    let mut prev_after = 0usize;
    for r in rs {
        allocated += r.used_before.saturating_sub(prev_after);
        prev_after = r.used_after;
    }
    allocated += used_now.saturating_sub(prev_after);
    let pause: f64 = rs.iter().map(|r| r.pause).sum();
    let gc: f64 = rs.iter().map(|r| r.gc).sum();
    let max_pause = rs.iter().map(|r| r.pause).fold(0.0, f64::max);
    let live = |r: &Record| if r.live > 0 { r.live } else { r.used_after };
    let max_live = rs.iter().map(live).max().unwrap_or(0);
    let survived: usize = rs.iter().map(live).sum();
    let workers = thread_cpu("mmtk-worker");
    let cpu = process_cpu();
    let n = rs.len().max(1) as f64;
    let mut out = format!(
        "kiln gc: {} collections in {wall:.1} s; pauses {pause:.2} s ({:.1}% of wall), mean {:.1} ms, max {:.1} ms; \
         world stopped {gc:.2} s\n",
        rs.len(),
        pause * 100.0 / wall.max(1e-9),
        pause * 1000.0 / n,
        max_pause * 1000.0,
    );
    out.push_str(&format!(
        "kiln gc: allocated {:.0} MiB; live after a collection: max {:.0} MiB, mean {:.0} MiB; \
         copied in total {:.0} MiB ({:.1}% of allocated)\n",
        allocated as f64 / MIB,
        max_live as f64 / MIB,
        survived as f64 / MIB / n,
        survived as f64 / MIB,
        survived as f64 * 100.0 / (allocated.max(1) as f64),
    ));
    out.push_str(&format!(
        "kiln gc: CPU {cpu:.1} s in the process, {workers:.1} s in GC workers ({:.1}%); {} static roots\n",
        workers * 100.0 / cpu.max(1e-9),
        crate::gc::static_roots().len()
    ));
    let young: usize = rs.iter().map(|r| r.young).sum();
    let old: usize = rs.iter().map(|r| r.old).sum();
    if young + old > 0 {
        out.push_str(&format!(
            "kiln gc: copied {:.0} MiB of objects allocated since the previous collection, \
             {:.0} MiB of objects copied before\n",
            young as f64 / MIB,
            old as f64 / MIB
        ));
    }
    eprint!("{out}");
    if let Some(path) = &s.path {
        let mut f = String::from("n\tat_s\tpause_ms\tgc_ms\tused_before_mib\tused_after_mib\tlive_mib\tyoung_mib\told_mib\n");
        for (i, r) in rs.iter().enumerate() {
            f.push_str(&format!(
                "{}\t{:.3}\t{:.2}\t{:.2}\t{:.1}\t{:.1}\t{:.1}\t{:.1}\t{:.1}\n",
                i + 1,
                r.at,
                r.pause * 1000.0,
                r.gc * 1000.0,
                r.used_before as f64 / MIB,
                r.used_after as f64 / MIB,
                r.live as f64 / MIB,
                r.young as f64 / MIB,
                r.old as f64 / MIB
            ));
        }
        let _ = std::fs::write(path, f);
    }
}
