//! Keep a bounded set of unbound native templates for top-level evaluation.
use super::recorded_code::CodeTemplate;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

const CACHE_ENTRIES: usize = 64;
pub(super) const CACHE_BYTES: usize = 8 * 1024 * 1024;

pub(super) struct Entry {
    pub template: CodeTemplate,
    pub literal_count: usize,
    pub patches: Vec<(String, u32, usize)>,
    packet: Vec<u8>,
    bytes: usize,
}

struct Cache {
    entries: VecDeque<Arc<Entry>>,
    bytes: usize,
}

static CACHE: Mutex<Cache> = Mutex::new(Cache {
    entries: VecDeque::new(),
    bytes: 0,
});

pub(super) fn lookup(packet: &[u8]) -> Option<Arc<Entry>> {
    let mut cache = CACHE.lock().unwrap();
    let index = cache
        .entries
        .iter()
        .position(|entry| entry.packet == packet)?;
    let entry = cache.entries.remove(index).unwrap();
    cache.entries.push_front(entry.clone());
    Some(entry)
}

pub(super) fn remember(
    packet: Vec<u8>,
    template: CodeTemplate,
    literal_count: usize,
    patches: Vec<(String, u32, usize)>,
) {
    let bytes = packet.len() + template.payload_bytes();
    if bytes > CACHE_BYTES {
        return;
    }
    let mut cache = CACHE.lock().unwrap();
    while cache.entries.len() >= CACHE_ENTRIES || cache.bytes + bytes > CACHE_BYTES {
        if let Some(entry) = cache.entries.pop_back() {
            cache.bytes -= entry.bytes;
        }
    }
    cache.bytes += bytes;
    cache.entries.push_front(Arc::new(Entry {
        template,
        literal_count,
        patches,
        packet,
        bytes,
    }));
}
