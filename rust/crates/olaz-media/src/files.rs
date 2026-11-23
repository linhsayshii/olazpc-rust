//! Disk helpers of the files cache (Swift `MediaLoader` part files, LRU trim, stale `.part`
//! cleanup). Layout is unchanged: `<files dir>/<stableHash>.<ext>` plus `.<id>.part` temporaries.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

/// `.part` files untouched for this long are leftovers from a crash / force-quit.
pub const STALE_PART_AGE: Duration = Duration::from_secs(600);

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A unique id for temporary names (process id, clock, counter; not a secret).
pub(crate) fn unique_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    format!(
        "{:x}{:x}{:x}",
        std::process::id(),
        nanos,
        COUNTER.fetch_add(1, Ordering::Relaxed)
    )
}

/// `<dir>/.<id>.part`.
pub(crate) fn part_file(dir: &Path) -> PathBuf {
    dir.join(format!(".{}.part", unique_id()))
}

/// Deletes the file when dropped (cancellation / error paths leave no partial file behind).
pub(crate) struct Cleanup(pub(crate) Vec<PathBuf>);

impl Cleanup {
    pub(crate) fn new() -> Self {
        Self(Vec::new())
    }
    pub(crate) fn add(&mut self, path: &Path) {
        self.0.push(path.to_owned());
    }
    pub(crate) fn forget(&mut self, path: &Path) {
        self.0.retain(|p| p != path);
    }
}

impl Drop for Cleanup {
    fn drop(&mut self) {
        for path in &self.0 {
            let _ = fs::remove_file(path);
        }
    }
}

/// Marks a cache hit as recently used (LRU).
pub(crate) fn touch(path: &Path) {
    if let Ok(file) = fs::OpenOptions::new().write(true).open(path) {
        let _ = file.set_modified(SystemTime::now());
    }
}

/// Flushes a finished temp file to disk before it gets its final name.
pub(crate) fn sync_to_disk(path: &Path) {
    if let Ok(file) = fs::OpenOptions::new().write(true).open(path) {
        let _ = file.sync_all();
    }
}

/// Deletes stale `.part` files (older than `part_age`, so never one an active download is still
/// writing) and evicts least-recently-used completed files until the total is within `limit`.
/// `keep` is never evicted (`MediaLoader.trimFiles`).
pub fn trim_files(
    directory: &Path,
    limit: u64,
    keep: Option<&Path>,
    part_age: Duration,
    now: SystemTime,
) {
    let Ok(read) = fs::read_dir(directory) else {
        return;
    };
    let mut entries: Vec<(PathBuf, u64, SystemTime)> = Vec::new();
    for item in read.flatten() {
        let path = item.path();
        let Ok(meta) = item.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        let modified = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH);
        let name = item.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            let age = now.duration_since(modified).unwrap_or_default();
            if name.ends_with(".part") && age > part_age {
                let _ = fs::remove_file(&path);
            }
            continue;
        }
        let used = meta.accessed().map_or(modified, |a| a.max(modified));
        entries.push((path, meta.len(), used));
    }
    let mut total: u64 = entries.iter().map(|e| e.1).sum();
    if total <= limit {
        return;
    }
    entries.sort_by_key(|e| e.2);
    for (path, size, _) in entries {
        if total <= limit {
            break;
        }
        if keep.is_some_and(|k| k == path) {
            continue;
        }
        let _ = fs::remove_file(&path);
        total = total.saturating_sub(size);
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use std::fs::File;

    fn make(dir: &Path, name: &str, size: usize, age_secs: u64) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, vec![0_u8; size]).unwrap();
        let t = SystemTime::now() - Duration::from_secs(age_secs);
        let f = File::options().write(true).open(&path).unwrap();
        f.set_times(fs::FileTimes::new().set_accessed(t).set_modified(t))
            .unwrap();
        path
    }

    #[test]
    fn removes_stale_parts_keeps_fresh_ones() {
        let dir = tempfile::tempdir().unwrap();
        let stale = make(dir.path(), ".a.part", 10, 3600);
        let fresh = make(dir.path(), ".b.part", 10, 5);
        let done = make(dir.path(), "c.pdf", 10, 3600);
        trim_files(
            dir.path(),
            1_000_000,
            None,
            STALE_PART_AGE,
            SystemTime::now(),
        );
        assert!(!stale.exists());
        assert!(fresh.exists());
        assert!(done.exists());
    }

    #[test]
    fn evicts_lru_first_and_spares_kept() {
        let dir = tempfile::tempdir().unwrap();
        let oldest = make(dir.path(), "old.bin", 100, 3000);
        let middle = make(dir.path(), "mid.bin", 100, 2000);
        let newest = make(dir.path(), "new.bin", 100, 1000);
        let part = make(dir.path(), ".x.part", 100, 1);
        trim_files(
            dir.path(),
            250,
            Some(&oldest),
            STALE_PART_AGE,
            SystemTime::now(),
        );
        assert!(oldest.exists());
        assert!(!middle.exists());
        assert!(newest.exists());
        assert!(part.exists());
        trim_files(dir.path(), 150, None, STALE_PART_AGE, SystemTime::now());
        assert!(!oldest.exists());
        assert!(newest.exists());
    }

    #[test]
    fn unique_ids_differ() {
        assert_ne!(unique_id(), unique_id());
        let d = Path::new("/tmp");
        let p = part_file(d);
        assert!(p.file_name().unwrap().to_string_lossy().starts_with('.'));
        assert!(p.to_string_lossy().ends_with(".part"));
    }

    #[test]
    fn cleanup_guard_removes_files() {
        let dir = tempfile::tempdir().unwrap();
        let a = make(dir.path(), "a", 1, 0);
        let b = make(dir.path(), "b", 1, 0);
        {
            let mut guard = Cleanup::new();
            guard.add(&a);
            guard.add(&b);
            guard.forget(&b);
        }
        assert!(!a.exists());
        assert!(b.exists());
    }
}
