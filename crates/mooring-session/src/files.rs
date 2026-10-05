//! Small owner-only JSON documents in Mooring's data directory, shared by the
//! saved-peer list and the sharing Mac's approved devices: a bounded read, a
//! cross-process lock, and atomic replacement that never leaves a partial file.

use crate::{Error, Result};
use std::fs::{self, File, OpenOptions, TryLockError};
use std::io::{Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// A process-unique number for temporary names.
pub(crate) fn next_sequence() -> u64 {
    SEQUENCE.fetch_add(1, Ordering::Relaxed)
}

/// The file's bytes, or None when it doesn't exist. Larger than `limit` or
/// unreadable is a storage error, so a caller never overwrites what it can't read.
pub(crate) fn read_bounded(path: &Path, limit: u64) -> Result<Option<Vec<u8>>> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(Error::Storage),
    };
    let mut bytes = Vec::new();
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::Storage)?;
    if bytes.len() as u64 > limit {
        return Err(Error::Storage);
    }
    Ok(Some(bytes))
}

/// Holds `name` in `directory` locked against other Mooring processes, for
/// up to 3 s of waiting. The lock lasts while the file stays open.
pub(crate) fn lock(directory: &Path, name: &str) -> Result<File> {
    fs::create_dir_all(directory).map_err(|_| Error::Storage)?;
    let mut options = OpenOptions::new();
    options.create(true).truncate(false).read(true).write(true);
    private_mode(&mut options);
    let file = options
        .open(directory.join(name))
        .map_err(|_| Error::Storage)?;
    let start = Instant::now();
    loop {
        match file.try_lock() {
            Ok(()) => return Ok(file),
            Err(TryLockError::WouldBlock) if start.elapsed() < Duration::from_secs(3) => {
                std::thread::sleep(Duration::from_millis(20))
            }
            Err(TryLockError::WouldBlock) => return Err(Error::Busy),
            Err(TryLockError::Error(_)) => return Err(Error::Storage),
        }
    }
}

/// Writes `bytes` to a new owner-only temporary file, syncs it and renames it
/// over `file_name`; rename is the commit point.
pub(crate) fn write_atomic(directory: &Path, file_name: &str, bytes: &[u8]) -> Result<()> {
    let temporary = directory.join(format!(
        ".{file_name}-{}-{}.tmp",
        std::process::id(),
        next_sequence()
    ));
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    private_mode(&mut options);
    let result = (|| -> std::io::Result<()> {
        let mut file = options.open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, directory.join(file_name))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map_err(|_| Error::Storage)?;
    // A failed directory sync does not undo the rename.
    let _ = File::open(directory).and_then(|directory| directory.sync_all());
    Ok(())
}

pub(crate) fn private_mode(options: &mut OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt;
    options.mode(0o600);
}
