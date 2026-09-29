//! Saved native-session peers: public metadata only (peer ID, display name and
//! address). Pairing secrets stay in Keychain. The file follows the CLI store's
//! conventions: bounded size, strict validation, owner-only permissions, atomic
//! replacement, a cross-process lock, and never overwriting a file it cannot read.

use crate::pairing::{PairingCode, normalize_address, validate_name};
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::fs::{self, File, OpenOptions, TryLockError};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

pub(crate) const MAX_PEERS: usize = 32;
const FILE_NAME: &str = "native-peers.json";
const LOCK_NAME: &str = "native-peers.lock";
const MAX_FILE_BYTES: u64 = 64 * 1024;
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Peer {
    pub id: String,
    pub name: String,
    pub address: String,
}

impl Peer {
    fn validated(self) -> Result<Self> {
        let valid_id = self.id.len() == 64
            && self
                .id
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte));
        if !valid_id {
            return Err(Error::Invalid);
        }
        validate_name(&self.name)?;
        Ok(Self {
            address: normalize_address(&self.address)?,
            ..self
        })
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    version: u32,
    peers: Vec<Peer>,
}

pub(crate) struct PeerStore {
    directory: PathBuf,
}

impl PeerStore {
    pub(crate) fn new(directory: PathBuf) -> Self {
        Self { directory }
    }
    pub(crate) fn default_location() -> Result<Self> {
        maclink_platform::support_directory()
            .map(Self::new)
            .map_err(|_| Error::Storage)
    }
    fn path(&self) -> PathBuf {
        self.directory.join(FILE_NAME)
    }

    /// Most recently connected first. A missing file is an empty list.
    pub(crate) fn load(&self) -> Result<Vec<Peer>> {
        let file = match File::open(self.path()) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
            Err(_) => return Err(Error::Storage),
        };
        let mut bytes = Vec::new();
        file.take(MAX_FILE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::Storage)?;
        if bytes.len() as u64 > MAX_FILE_BYTES {
            return Err(Error::Storage);
        }
        let document: Document = serde_json::from_slice(&bytes).map_err(|_| Error::Storage)?;
        if document.version != 1 || document.peers.len() > MAX_PEERS {
            return Err(Error::Storage);
        }
        let mut ids = HashSet::new();
        document
            .peers
            .into_iter()
            .map(|peer| {
                let peer = peer.validated().map_err(|_| Error::Storage)?;
                if ids.insert(peer.id.clone()) {
                    Ok(peer)
                } else {
                    Err(Error::Storage)
                }
            })
            .collect()
    }

    /// Save or refresh a peer after an authenticated connection.
    pub(crate) fn remember(&self, code: &PairingCode, address: &str) -> Result<Peer> {
        let peer = Peer {
            id: code.peer_id(),
            name: code.name.clone(),
            address: address.to_owned(),
        }
        .validated()?;
        let _lock = self.lock()?;
        let mut peers = self.load()?;
        peers.retain(|saved| saved.id != peer.id);
        peers.insert(0, peer.clone());
        peers.truncate(MAX_PEERS);
        self.save(peers)?;
        Ok(peer)
    }

    /// One-time migration of the earlier preference list: `[{id,name,address}]`.
    /// Invalid entries are skipped as before. A readable existing store wins; an
    /// unreadable one fails, so the caller keeps the legacy list.
    pub(crate) fn import_legacy(&self, bytes: &[u8]) -> Result<usize> {
        if bytes.len() as u64 > MAX_FILE_BYTES {
            return Err(Error::Invalid);
        }
        let entries: Vec<Value> = serde_json::from_slice(bytes).map_err(|_| Error::Invalid)?;
        let _lock = self.lock()?;
        if self.path().exists() {
            self.load()?;
            return Ok(0);
        }
        let mut ids = HashSet::new();
        let peers: Vec<Peer> = entries
            .into_iter()
            .filter_map(|entry| serde_json::from_value::<Peer>(entry).ok()?.validated().ok())
            .filter(|peer| ids.insert(peer.id.clone()))
            .take(MAX_PEERS)
            .collect();
        let count = peers.len();
        self.save(peers)?;
        Ok(count)
    }

    fn lock(&self) -> Result<File> {
        fs::create_dir_all(&self.directory).map_err(|_| Error::Storage)?;
        let mut options = OpenOptions::new();
        options.create(true).truncate(false).read(true).write(true);
        private_mode(&mut options);
        let file = options
            .open(self.directory.join(LOCK_NAME))
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

    fn save(&self, peers: Vec<Peer>) -> Result<()> {
        let mut bytes = serde_json::to_vec_pretty(&Document { version: 1, peers })
            .map_err(|_| Error::Internal)?;
        bytes.push(b'\n');
        let temporary = self.directory.join(format!(
            ".native-peers-{}-{}.tmp",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        private_mode(&mut options);
        let result = (|| -> std::io::Result<()> {
            let mut file = options.open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temporary, self.path())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result.map_err(|_| Error::Storage)?;
        // Rename is the commit point; directory sync failure does not undo it.
        let _ = File::open(&self.directory).and_then(|directory| directory.sync_all());
        Ok(())
    }
}

fn private_mode(options: &mut OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt;
    options.mode(0o600);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pairing::tests::code;

    pub(crate) struct Directory(pub PathBuf);
    impl Directory {
        pub(crate) fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "maclink-peers-{}-{}",
                std::process::id(),
                SEQUENCE.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn store(&self) -> PeerStore {
            PeerStore::new(self.0.clone())
        }
    }
    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn peer_code(index: u8) -> PairingCode {
        PairingCode::new(
            "studio.local",
            &format!("Mac {index}"),
            [index; 32],
            [7; 32],
        )
        .unwrap()
    }

    #[test]
    fn remembered_peers_round_trip_most_recent_first() {
        let directory = Directory::new();
        assert!(directory.store().load().unwrap().is_empty());
        let first = directory
            .store()
            .remember(&peer_code(1), "Studio.Local")
            .unwrap();
        assert_eq!(first.address, "studio.local");
        directory
            .store()
            .remember(&peer_code(2), "192.168.1.25")
            .unwrap();
        let moved = directory
            .store()
            .remember(&peer_code(1), "office.local")
            .unwrap();
        let peers = directory.store().load().unwrap();
        assert_eq!(peers.len(), 2);
        assert_eq!(peers[0], moved);
        assert_eq!(peers[0].address, "office.local");
        assert_eq!(peers[1].name, "Mac 2");
    }

    #[test]
    fn list_is_bounded_and_file_is_private_without_secrets() {
        use std::os::unix::fs::PermissionsExt;
        let directory = Directory::new();
        for index in 0..40 {
            directory
                .store()
                .remember(&peer_code(index), "studio.local")
                .unwrap();
        }
        let peers = directory.store().load().unwrap();
        assert_eq!(peers.len(), MAX_PEERS);
        assert_eq!(peers[0].name, "Mac 39");
        let path = directory.0.join(FILE_NAME);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let saved = code();
        directory.store().remember(&saved, "studio.local").unwrap();
        let text = fs::read_to_string(&path).unwrap();
        let credential = String::from_utf8(saved.credential().to_vec()).unwrap();
        let object: Value = serde_json::from_str(&credential).unwrap();
        for sensitive in [
            object["secret"].as_str().unwrap(),
            object["publicKey"].as_str().unwrap(),
            "secret",
            "publicKey",
        ] {
            assert!(!text.contains(sensitive), "{sensitive}");
        }
    }

    #[test]
    fn invalid_address_is_rejected_before_writing() {
        let directory = Directory::new();
        assert_eq!(
            directory
                .store()
                .remember(&peer_code(1), "vnc://studio.local"),
            Err(Error::Invalid)
        );
        assert!(!directory.0.join(FILE_NAME).exists());
    }

    #[test]
    fn corrupt_future_or_oversized_files_are_never_overwritten() {
        let directory = Directory::new();
        let path = directory.0.join(FILE_NAME);
        let id = "a".repeat(64);
        let peer = |id: &str, name: &str, address: &str| serde_json::json!({"id": id, "name": name, "address": address});
        let many: Vec<Value> = (0..33)
            .map(|index| peer(&format!("{index:064x}"), "Mac", "mac.local"))
            .collect();
        for content in [
            "{invalid".to_owned(),
            serde_json::json!({"version": 2, "peers": []}).to_string(),
            serde_json::json!({"version": 1, "peers": [peer(&id, "Mac", "mac.local"), peer(&id, "Mac", "mac.local")]}).to_string(),
            serde_json::json!({"version": 1, "peers": [peer("ABC", "Mac", "mac.local")]}).to_string(),
            serde_json::json!({"version": 1, "peers": [peer(&id, "Mac\u{202e}", "mac.local")]}).to_string(),
            serde_json::json!({"version": 1, "peers": [peer(&id, "Mac", "user@mac.local")]}).to_string(),
            serde_json::json!({"version": 1, "peers": many}).to_string(),
            " ".repeat(MAX_FILE_BYTES as usize + 1),
        ] {
            fs::write(&path, &content).unwrap();
            assert_eq!(directory.store().load(), Err(Error::Storage));
            assert!(directory.store().remember(&peer_code(1), "mac.local").is_err());
            assert_eq!(fs::read_to_string(&path).unwrap(), content);
        }
    }

    #[test]
    fn legacy_preferences_import_once_and_skip_invalid_entries() {
        let directory = Directory::new();
        let valid = |index: u8| serde_json::json!({"id": peer_code(index).peer_id(), "name": format!("Mac {index}"), "address": "mac.local"});
        let mut legacy = vec![
            valid(1),
            valid(1),
            serde_json::json!({"id": "short", "name": "Mac", "address": "mac.local"}),
        ];
        legacy.push(serde_json::json!({"id": peer_code(2).peer_id(), "name": "Mac", "address": "http://mac.local"}));
        legacy.push(serde_json::json!("not an object"));
        legacy.extend((3..40).map(valid));
        let bytes = serde_json::to_vec(&legacy).unwrap();
        assert_eq!(directory.store().import_legacy(&bytes).unwrap(), MAX_PEERS);
        let peers = directory.store().load().unwrap();
        assert_eq!(peers.len(), MAX_PEERS);
        assert_eq!(peers[0].name, "Mac 1");
        assert_eq!(peers[1].name, "Mac 3");
        assert_eq!(
            directory.store().import_legacy(b"[]").unwrap(),
            0,
            "an existing store wins"
        );
        assert_eq!(directory.store().load().unwrap(), peers);
        assert_eq!(
            Directory::new().store().import_legacy(b"{not json"),
            Err(Error::Invalid)
        );
        let corrupt = Directory::new();
        fs::write(corrupt.0.join(FILE_NAME), "{invalid").unwrap();
        assert_eq!(
            corrupt.store().import_legacy(&bytes),
            Err(Error::Storage),
            "keep the legacy list"
        );
    }

    #[test]
    fn concurrent_remembers_do_not_lose_peers() {
        let directory = Directory::new();
        std::thread::scope(|scope| {
            for index in 0..12 {
                let path = directory.0.clone();
                scope.spawn(move || {
                    PeerStore::new(path)
                        .remember(&peer_code(index), "mac.local")
                        .unwrap()
                });
            }
        });
        assert_eq!(directory.store().load().unwrap().len(), 12);
    }
}
