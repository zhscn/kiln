//! The sampling profiler.
//!
//! CPU (wall-clock) mode: a timer thread counts ticks and sets the
//! profiled context's `poll_flag`; the next poll point (function entries,
//! loop heads) records the stack, weighted by the ticks since the last
//! sample. Time spent in the runtime (bignums, number operations) is so
//! charged to the Lisp frames that called it, by its duration.
//!
//! Allocation mode: the allocation slow path (a bump allocator refill, or
//! a large object) records the stack, weighted by the bytes allocated
//! since the last sample.
//!
//! A sample is the list of the functions on the stack (the start address
//! of each frame's function), innermost first. Lisp reads the samples
//! through `kiln_rt_frame` (the PROFILE_* operations) and names the
//! functions from their debug info objects.

use crate::context::Context;
use std::collections::HashMap;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};

pub const MODE_CPU: u64 = 0;
pub const MODE_ALLOC: u64 = 1;

/// Most frames recorded per sample.
const MAX_DEPTH: usize = 256;

static CPU_ACTIVE: AtomicBool = AtomicBool::new(false);
pub static ALLOC_ACTIVE: AtomicBool = AtomicBool::new(false);
static TICKS: AtomicU64 = AtomicU64::new(0);
/// The profiled context, for the timer thread.
static CONTEXT: AtomicUsize = AtomicUsize::new(0);
/// Bumps when profiling stops, so that an old timer thread ends.
static GENERATION: AtomicU64 = AtomicU64::new(0);

struct State {
    samples: HashMap<Vec<usize>, u64>,
    /// The samples as a list, for indexed access by Lisp after STOP.
    list: Vec<(Vec<usize>, u64)>,
    /// Allocation mode: the bump allocator's cursor after the last sample.
    last_cursor: usize,
}

static STATE: Mutex<Option<State>> = Mutex::new(None);
static TIMER: Mutex<Option<std::thread::JoinHandle<()>>> = Mutex::new(None);

/// Starts profiling `ctx`, forgetting earlier samples.
pub fn start(ctx: *mut Context, mode: u64, interval_us: u64) {
    stop();
    *STATE.lock().unwrap() =
        Some(State { samples: HashMap::new(), list: Vec::new(), last_cursor: 0 });
    CONTEXT.store(ctx as usize, Ordering::Relaxed);
    TICKS.store(0, Ordering::Relaxed);
    if mode == MODE_ALLOC {
        ALLOC_ACTIVE.store(true, Ordering::Release);
        return;
    }
    CPU_ACTIVE.store(true, Ordering::Release);
    let generation = GENERATION.load(Ordering::Relaxed);
    let interval = std::time::Duration::from_micros(interval_us.max(50));
    let timer = std::thread::Builder::new()
        .name("kiln-profiler".into())
        .spawn(move || {
            while GENERATION.load(Ordering::Relaxed) == generation {
                std::thread::park_timeout(interval);
                if GENERATION.load(Ordering::Acquire) != generation {
                    break;
                }
                TICKS.fetch_add(1, Ordering::Relaxed);
                let ctx = CONTEXT.load(Ordering::Relaxed) as *mut Context;
                // Plain stores, as the poll points read them; a lost
                // update only delays the sample (its ticks are kept).
                unsafe { crate::context::request_poll(ctx) };
            }
        })
        .expect("cannot start the profiler thread");
    *TIMER.lock().unwrap() = Some(timer);
}

/// Stops profiling; the samples stay readable until the next start.
pub fn stop() {
    CPU_ACTIVE.store(false, Ordering::Release);
    ALLOC_ACTIVE.store(false, Ordering::Release);
    GENERATION.fetch_add(1, Ordering::AcqRel);
    if let Some(timer) = TIMER.lock().unwrap().take() {
        timer.thread().unpark();
        timer.join().expect("profiler timer thread panicked");
    }
    if let Some(s) = STATE.lock().unwrap().as_mut() {
        let mut list: Vec<_> = s.samples.drain().collect();
        list.sort_by(|a, b| b.1.cmp(&a.1));
        s.list.extend(list);
    }
}

/// The function start addresses of the frames from `fp` outwards, through
/// the suspended segments (as `debug::list_frames`). When `entry` is
/// non-zero (`kiln_poll_retry`), it replaces the innermost frame (`fp` is
/// the trampoline called by `kiln_poll_retry`, which replaced `entry`).
unsafe fn walk(ctx: &Context, entry: usize, fp: usize) -> Vec<usize> {
    let mut frames = Vec::new();
    let mut fp = fp;
    let mut base = ctx.stack_base_fp;
    let mut seg = ctx.segments;
    if entry != 0 && fp != base && fp != 0 {
        frames.push(entry);
        fp = unsafe { *(fp as *const usize) };
    }
    loop {
        while fp != base && fp != 0 && frames.len() < MAX_DEPTH {
            let ret = unsafe { *((fp + 8) as *const usize) };
            if let Some(r) = crate::debug::lookup(ret) {
                frames.push(r.start);
            }
            fp = unsafe { *(fp as *const usize) };
        }
        if seg.is_null() || frames.len() >= MAX_DEPTH {
            return frames;
        }
        unsafe {
            fp = (*seg).top_fp;
            base = (*seg).base_fp;
            seg = (*seg).prev;
        }
    }
}

fn record(ctx: *mut Context, entry: usize, fp: usize, weight: u64) {
    let frames = unsafe { walk(&*ctx, entry, fp) };
    if let Some(s) = STATE.lock().unwrap().as_mut() {
        *s.samples.entry(frames).or_insert(0) += weight;
    }
}

/// Called by every poll slow path (`kiln_rt_poll`); `fp` is the frame
/// pointer of its trampoline, `entry` the function `kiln_poll_retry`
/// will re-enter (0 from an in-function poll).
pub fn poll(ctx: *mut Context, entry: usize, fp: usize) {
    if CPU_ACTIVE.load(Ordering::Relaxed) && CONTEXT.load(Ordering::Relaxed) == ctx as usize {
        let ticks = TICKS.swap(0, Ordering::Relaxed);
        if ticks > 0 {
            record(ctx, entry, fp, ticks);
        }
    }
}

/// Called by the allocation slow path before it allocates `bytes`, with
/// the bump allocator's cursor; returns nothing, records a sample
/// weighted by the bytes allocated since the last one.
pub fn note_alloc(ctx: *mut Context, fp: usize, cursor: usize, bytes: usize) {
    let weight = {
        let mut state = STATE.lock().unwrap();
        let Some(s) = state.as_mut() else { return };
        let since = if s.last_cursor != 0 && cursor >= s.last_cursor { cursor - s.last_cursor } else { 0 };
        s.last_cursor = 0;
        since + bytes
    };
    record(ctx, 0, fp, weight as u64);
}

/// Called after the allocation slow path refilled the bump allocator.
pub fn note_refill(cursor: usize) {
    if let Some(s) = STATE.lock().unwrap().as_mut() {
        s.last_cursor = cursor;
    }
}

pub const PROFILE_START: u64 = 32;
pub const PROFILE_STOP: u64 = 33;
pub const PROFILE_COUNT: u64 = 34;
pub const PROFILE_WEIGHT: u64 = 35;
pub const PROFILE_DEPTH: u64 = 36;
pub const PROFILE_FRAME_INFO: u64 = 37;

/// The PROFILE_* operations of `kiln_rt_frame` (fixnum arguments): START
/// (mode, interval in µs), STOP, COUNT (samples), WEIGHT (i), DEPTH (i),
/// FRAME_INFO (i, j): the debug info object of frame j of sample i.
pub fn op(ctx: *mut Context, op: u64, a: u64, b: u64) -> u64 {
    let fixnum = |n: u64| n << 1;
    let nil = crate::object::nil();
    match op {
        PROFILE_START => {
            start(ctx, a >> 1, b >> 1);
            nil
        }
        PROFILE_STOP => {
            stop();
            nil
        }
        _ => {
            let state = STATE.lock().unwrap();
            let Some(s) = state.as_ref() else { return fixnum(0) };
            let sample = s.list.get((a >> 1) as usize);
            match (op, sample) {
                (PROFILE_COUNT, _) => fixnum(s.list.len() as u64),
                (PROFILE_WEIGHT, Some((_, w))) => fixnum(*w),
                (PROFILE_DEPTH, Some((frames, _))) => fixnum(frames.len() as u64),
                (PROFILE_FRAME_INFO, Some((frames, _))) => frames
                    .get((b >> 1) as usize)
                    .and_then(|&start| crate::debug::lookup(start + 1))
                    .map_or(nil, |r| crate::debug::info_object(&r)),
                _ => nil,
            }
        }
    }
}

/// Set when KILN_PROFILE started the profiler: `finish_from_env` writes
/// the results when the program ends.
static FROM_ENV: AtomicBool = AtomicBool::new(false);

/// `KILN_PROFILE=cpu[:MICROSECONDS]` or `alloc`: profiles the whole
/// program; `finish_from_env` writes the samples, as folded stacks for
/// flame graphs, to `KILN_PROFILE_OUT` (default `kiln-profile.folded`) and
/// a summary to standard error.
pub fn start_from_env(ctx: *mut Context) {
    let Ok(spec) = std::env::var("KILN_PROFILE") else { return };
    let (mode, interval) = match spec.split_once(':') {
        Some((m, i)) => (m.to_string(), i.parse().unwrap_or(1000)),
        None => (spec, 1000),
    };
    let mode = if mode == "alloc" { MODE_ALLOC } else { MODE_CPU };
    FROM_ENV.store(true, Ordering::Relaxed);
    start(ctx, mode, interval);
}

/// The name of the function starting at `start`, printed.
fn function_name(start: usize) -> String {
    let mut s = String::new();
    match crate::debug::lookup(start + 1).map(|r| crate::debug::info_object(&r)) {
        Some(info) if info != crate::object::nil() => unsafe {
            crate::object::write_object(&mut s, *((crate::object::untag(info) + 8) as *const u64));
        },
        _ => {
            use std::fmt::Write;
            let _ = write!(s, "#x{start:x}");
        }
    }
    s.replace(';', ":")
}

pub fn finish_from_env() {
    if !FROM_ENV.swap(false, Ordering::Relaxed) {
        stop();
        return;
    }
    let alloc = ALLOC_ACTIVE.load(Ordering::Relaxed);
    stop();
    let state = STATE.lock().unwrap();
    let Some(s) = state.as_ref() else { return };
    let mut names: HashMap<usize, String> = HashMap::new();
    let mut name = |start: usize| names.entry(start).or_insert_with(|| function_name(start)).clone();
    let path = std::env::var("KILN_PROFILE_OUT").unwrap_or_else(|_| "kiln-profile.folded".into());
    let mut folded = String::new();
    let mut self_w: HashMap<String, u64> = HashMap::new();
    let mut total_w: HashMap<String, u64> = HashMap::new();
    let mut total = 0;
    for (frames, w) in &s.list {
        total += w;
        let stack: Vec<String> = frames.iter().map(|&f| name(f)).collect();
        if let Some(first) = stack.first() {
            *self_w.entry(first.clone()).or_insert(0) += w;
        }
        let mut seen = std::collections::HashSet::new();
        for n in &stack {
            if seen.insert(n.clone()) {
                *total_w.entry(n.clone()).or_insert(0) += w;
            }
        }
        let outer_first: Vec<&str> = stack.iter().rev().map(|s| s.as_str()).collect();
        folded.push_str(&outer_first.join(";"));
        folded.push_str(&format!(" {w}\n"));
    }
    let _ = std::fs::write(&path, folded);
    let unit = if alloc { "bytes" } else { "ticks" };
    let mut out = format!("kiln profile: {total} {unit}, {} stacks, folded stacks in {path}\n", s.list.len());
    for (title, table) in [("self", &self_w), ("total", &total_w)] {
        let mut rows: Vec<_> = table.iter().collect();
        rows.sort_by(|a, b| b.1.cmp(a.1));
        out.push_str(&format!("  by {title}:\n"));
        for (n, w) in rows.into_iter().take(25) {
            let pct = if total > 0 { *w as f64 * 100.0 / total as f64 } else { 0.0 };
            let n: String = n.chars().take(100).collect();
            out.push_str(&format!("  {pct:6.2}% {w:>12}  {n}\n"));
        }
    }
    eprint!("{out}");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn stop_quiesces_timer_and_interrupts_long_wait() {
        // The timer only accesses poll_flag and stack_limit; no Lisp or GC runs.
        let mut ctx: Context = unsafe { std::mem::zeroed() };
        for _ in 0..8 {
            start(&mut ctx, MODE_CPU, 50);
            std::thread::sleep(Duration::from_millis(1));
            stop();
            ctx.poll_flag = 0;
            ctx.stack_limit = 0;
            std::thread::sleep(Duration::from_millis(1));
            assert_eq!(ctx.poll_flag, 0);
            assert_eq!(ctx.stack_limit, 0);
        }
        start(&mut ctx, MODE_CPU, 10_000_000);
        let began = Instant::now();
        stop();
        assert!(began.elapsed() < Duration::from_secs(1));
    }
}
