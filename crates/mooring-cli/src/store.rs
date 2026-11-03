use mooring_platform::ServerKind;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions, TryLockError},
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const MAX_STORE_BYTES: u64 = 1024 * 1024;
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// A saved VNC endpoint. With `ssh`, `host` and `port` are as seen from the
/// SSH host (usually 127.0.0.1:5900) and the viewer is pointed at a local
/// tunnel instead. The new fields are omitted when unset, so connections saved
/// before them are written back byte-for-byte unchanged.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Connection {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    #[serde(default, skip_serializing_if = "ServerKind::is_mac")]
    pub server: ServerKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh: Option<SshHop>,
}

/// The SSH destination: a `~/.ssh/config` alias or user@host. Keys, ports and
/// jump hosts stay in the user's SSH configuration; nothing secret is saved.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SshHop {
    pub target: String,
}

/// What `add` saves, before an ID is assigned.
pub struct NewConnection<'a> {
    pub name: &'a str,
    pub host: &'a str,
    pub port: u16,
    pub server: ServerKind,
    pub ssh_target: Option<&'a str>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    version: u32,
    connections: Vec<Connection>,
}

pub struct Store {
    directory: PathBuf,
}

impl Store {
    pub fn new(directory: PathBuf) -> Self {
        Self { directory }
    }

    pub fn default_path() -> Result<PathBuf, String> {
        mooring_platform::support_directory()
    }

    pub fn list(&self) -> Result<Vec<Connection>, String> {
        let path = self.directory.join("connections.json");
        let file = match File::open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
            Err(error) => return Err(format!("Cannot read {}: {error}", path.display())),
        };
        let mut bytes = Vec::new();
        file.take(MAX_STORE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| format!("Cannot read connections: {e}"))?;
        if bytes.len() as u64 > MAX_STORE_BYTES {
            return Err("Connection file exceeds the 1 MiB limit; it has not been changed".into());
        }
        let mut document: Document = serde_json::from_slice(&bytes)
            .map_err(|e| format!("Connection file is invalid and has not been changed: {e}"))?;
        if document.version != 1 {
            return Err(format!(
                "Unsupported connection file version {}; file has not been changed",
                document.version
            ));
        }
        let mut ids = HashSet::new();
        for connection in &mut document.connections {
            connection.name = validate_name(&connection.name)?;
            connection.host = mooring_platform::validate_host(&connection.host)?;
            if let Some(ssh) = &mut connection.ssh {
                ssh.target = mooring_platform::ssh::validate_ssh_target(&ssh.target)?;
            }
            if connection.port == 0
                || !valid_id(&connection.id)
                || !ids.insert(connection.id.clone())
            {
                return Err(
                    "Connection file has invalid or duplicate entries; it has not been changed"
                        .into(),
                );
            }
        }
        Ok(document.connections)
    }

    pub fn get(&self, id: &str) -> Result<Connection, String> {
        self.list()?
            .into_iter()
            .find(|c| c.id == id)
            .ok_or_else(|| format!("Saved Mac '{id}' was not found. Run mooring list."))
    }

    #[cfg(test)]
    pub fn add(&self, name: &str, host: &str, port: u16) -> Result<Connection, String> {
        self.add_connection(NewConnection {
            name,
            host,
            port,
            server: ServerKind::Mac,
            ssh_target: None,
        })
    }

    pub fn add_connection(&self, new: NewConnection) -> Result<Connection, String> {
        let name = validate_name(new.name)?;
        let host = mooring_platform::validate_host(new.host)?;
        let port = new.port;
        if port == 0 {
            return Err("Port must be between 1 and 65535".into());
        }
        let ssh = new
            .ssh_target
            .map(mooring_platform::ssh::validate_ssh_target)
            .transpose()?
            .map(|target| SshHop { target });
        let _lock = self.lock()?;
        let mut connections = self.list()?;
        // The same remote endpoint through different SSH hosts is a different
        // connection; 127.0.0.1:5900 is the usual endpoint for every one.
        let same_route = |c: &Connection| match (&c.ssh, &ssh) {
            (None, None) => true,
            (Some(a), Some(b)) => a.target.eq_ignore_ascii_case(&b.target),
            _ => false,
        };
        if connections
            .iter()
            .any(|c| c.host.eq_ignore_ascii_case(&host) && c.port == port && same_route(c))
        {
            return Err(if ssh.is_some() {
                "This SSH host, VNC address and port are already saved".into()
            } else {
                "This Mac and port are already saved".into()
            });
        }
        let connection = Connection {
            id: unique_id(),
            name,
            host,
            port,
            server: new.server,
            ssh,
        };
        connections.push(connection.clone());
        self.save(connections)?;
        Ok(connection)
    }

    pub fn remove(&self, id: &str) -> Result<(), String> {
        let _lock = self.lock()?;
        let mut connections = self.list()?;
        let index = connections
            .iter()
            .position(|c| c.id == id)
            .ok_or_else(|| format!("Saved Mac '{id}' was not found"))?;
        connections.remove(index);
        self.save(connections)
    }

    fn lock(&self) -> Result<File, String> {
        fs::create_dir_all(&self.directory)
            .map_err(|e| format!("Cannot create connection directory: {e}"))?;
        let mut options = OpenOptions::new();
        options.create(true).truncate(false).read(true).write(true);
        private_mode(&mut options);
        let file = options
            .open(self.directory.join("connections.lock"))
            .map_err(|e| format!("Cannot open connection lock: {e}"))?;
        let start = Instant::now();
        loop {
            match file.try_lock() {
                Ok(()) => return Ok(file),
                Err(TryLockError::WouldBlock) if start.elapsed() < Duration::from_secs(3) => {
                    std::thread::sleep(Duration::from_millis(20))
                }
                Err(TryLockError::WouldBlock) => {
                    return Err("Another Mooring process is saving connections; try again".into());
                }
                Err(TryLockError::Error(error)) => {
                    return Err(format!("Cannot lock connections: {error}"));
                }
            }
        }
    }

    fn save(&self, connections: Vec<Connection>) -> Result<(), String> {
        let mut bytes = serde_json::to_vec_pretty(&Document {
            version: 1,
            connections,
        })
        .map_err(|e| format!("Cannot encode connections: {e}"))?;
        bytes.push(b'\n');
        if bytes.len() as u64 > MAX_STORE_BYTES {
            return Err("Too many saved connections".into());
        }
        let temporary = self
            .directory
            .join(format!(".connections-{}.tmp", unique_id()));
        let mut options = OpenOptions::new();
        options.create_new(true).write(true);
        private_mode(&mut options);
        let result = (|| -> std::io::Result<()> {
            let mut file = options.open(&temporary)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            fs::rename(&temporary, self.directory.join("connections.json"))?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result.map_err(|e| format!("Cannot save connections: {e}"))?;
        // Rename is the commit point. Reporting a failed mutation after it would
        // invite duplicate retries and leave the UI displaying stale state.
        if let Err(error) = File::open(&self.directory).and_then(|file| file.sync_all()) {
            eprintln!(
                "Mooring: connections were saved, but directory durability could not be confirmed: {error}"
            );
        }
        Ok(())
    }
}

fn private_mode(options: &mut OpenOptions) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    #[cfg(not(unix))]
    let _ = options;
}

fn unique_id() -> String {
    let time = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!(
        "{time:x}-{:x}-{:x}",
        std::process::id(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    )
}

fn valid_id(id: &str) -> bool {
    let parts: Vec<&str> = id.split('-').collect();
    id.len() <= 128
        && parts.len() == 3
        && parts
            .iter()
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_hexdigit()))
}

fn validate_name(name: &str) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 80 || name.chars().any(char::is_control) {
        return Err("Name must contain 1–80 characters without control characters".into());
    }
    Ok(name.to_owned())
}

pub fn path_display(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    struct TestDirectory(PathBuf);
    impl TestDirectory {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("mooring-store-{}", unique_id()));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn store(&self) -> Store {
            Store::new(self.0.clone())
        }
    }
    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn persistence_round_trip_and_remove() {
        let directory = TestDirectory::new();
        let first = directory
            .store()
            .add(" Office Mac ", "office.local", 5900)
            .unwrap();
        assert_eq!(directory.store().get(&first.id).unwrap().name, "Office Mac");
        directory.store().remove(&first.id).unwrap();
        assert!(directory.store().list().unwrap().is_empty());
    }

    #[test]
    fn corrupt_or_future_store_is_never_overwritten() {
        let directory = TestDirectory::new();
        let path = directory.0.join("connections.json");
        for content in ["{invalid", "{\"version\":2,\"connections\":[]}"] {
            fs::write(&path, content).unwrap();
            assert!(directory.store().add("Mac", "mac.local", 5900).is_err());
            assert_eq!(fs::read_to_string(&path).unwrap(), content);
        }
    }

    #[test]
    fn concurrent_adds_do_not_lose_connections() {
        let directory = TestDirectory::new();
        std::thread::scope(|scope| {
            for index in 0..12 {
                let path = directory.0.clone();
                scope.spawn(move || {
                    Store::new(path)
                        .add(&format!("Mac {index}"), &format!("mac-{index}.local"), 5900)
                        .unwrap()
                });
            }
        });
        assert_eq!(directory.store().list().unwrap().len(), 12);
    }

    #[test]
    fn validates_before_writing() {
        let directory = TestDirectory::new();
        assert!(directory.store().add(" ", "mac.local", 5900).is_err());
        assert!(
            directory
                .store()
                .add("Mac", "user:password@mac.local", 5900)
                .is_err()
        );
        assert!(directory.store().add("Mac", "mac.local", 0).is_err());
        assert!(directory.store().list().unwrap().is_empty());
        directory.store().add("Mac", "mac.local", 5900).unwrap();
        assert!(
            directory
                .store()
                .add("Duplicate", "MAC.LOCAL", 5900)
                .is_err()
        );
    }

    #[test]
    fn stored_identifiers_are_bounded_and_loaded_labels_normalized() {
        let directory = TestDirectory::new();
        let path = directory.0.join("connections.json");
        for id in ["x".repeat(100_000), "bad\nidentifier".into(), "a--b".into()] {
            let document = serde_json::json!({"version":1,"connections":[{"id":id,"name":"Mac","host":"mac.local","port":5900}]});
            fs::write(&path, serde_json::to_vec(&document).unwrap()).unwrap();
            assert!(directory.store().list().is_err());
        }
        let document = serde_json::json!({"version":1,"connections":[{"id":"a-b-c","name":"  Mac \n","host":"MAC.LOCAL","port":5900}]});
        fs::write(&path, serde_json::to_vec(&document).unwrap()).unwrap();
        let saved = directory.store().list().unwrap();
        assert_eq!(saved[0].name, "Mac");
        assert_eq!(saved[0].host, "mac.local");
    }

    fn ssh_connection<'a>(target: &'a str, host: &'a str) -> NewConnection<'a> {
        NewConnection {
            name: "M1 Linux",
            host,
            port: 5900,
            server: ServerKind::Vnc,
            ssh_target: Some(target),
        }
    }

    #[test]
    fn existing_connections_are_unchanged_by_the_new_fields() {
        let directory = TestDirectory::new();
        let path = directory.0.join("connections.json");
        let legacy = serde_json::json!({"version":1,"connections":[{"id":"a-b-c","name":"Office","host":"office.local","port":5900}]});
        fs::write(&path, serde_json::to_vec_pretty(&legacy).unwrap()).unwrap();
        let loaded = directory.store().list().unwrap();
        assert_eq!(loaded[0].server, ServerKind::Mac);
        assert!(loaded[0].ssh.is_none());
        // Saving another connection writes the old one back without new keys.
        directory
            .store()
            .add_connection(ssh_connection("m1-linux", "127.0.0.1"))
            .unwrap();
        let document: serde_json::Value =
            serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(document["connections"][0], legacy["connections"][0]);
        assert_eq!(document["connections"][1]["server"], "vnc");
        assert_eq!(document["connections"][1]["ssh"]["target"], "m1-linux");
    }

    #[test]
    fn ssh_connections_round_trip_and_are_deduplicated_per_ssh_host() {
        let directory = TestDirectory::new();
        let store = directory.store();
        let saved = store
            .add_connection(ssh_connection("alex@192.0.2.20", "127.0.0.1"))
            .unwrap();
        let loaded = store.get(&saved.id).unwrap();
        assert_eq!(
            loaded.ssh,
            Some(SshHop {
                target: "alex@192.0.2.20".into()
            })
        );
        assert_eq!((loaded.host.as_str(), loaded.port), ("127.0.0.1", 5900));
        assert_eq!(loaded.server, ServerKind::Vnc);
        assert!(
            store
                .add_connection(ssh_connection("alex@192.0.2.20", "127.0.0.1"))
                .is_err()
        );
        // Another SSH host, or a direct connection, may share the endpoint.
        store
            .add_connection(ssh_connection("m1-linux", "127.0.0.1"))
            .unwrap();
        store.add("Local", "127.0.0.1", 5900).unwrap();
        assert_eq!(store.list().unwrap().len(), 3);
    }

    #[test]
    fn invalid_ssh_targets_are_never_saved_or_loaded() {
        let directory = TestDirectory::new();
        for target in ["-oProxyCommand=id", "host -v", "host:22", "user@", ""] {
            assert!(
                directory
                    .store()
                    .add_connection(ssh_connection(target, "127.0.0.1"))
                    .is_err(),
                "saved {target:?}"
            );
        }
        assert!(directory.store().list().unwrap().is_empty());
        let path = directory.0.join("connections.json");
        for entry in [
            serde_json::json!({"id":"a-b-c","name":"X","host":"127.0.0.1","port":5900,"ssh":{"target":"-oProxyCommand=id"}}),
            serde_json::json!({"id":"a-b-c","name":"X","host":"127.0.0.1","port":5900,"ssh":{"target":"h","port":22}}),
            serde_json::json!({"id":"a-b-c","name":"X","host":"127.0.0.1","port":5900,"server":"linux"}),
        ] {
            let document = serde_json::json!({"version":1,"connections":[entry]});
            fs::write(&path, serde_json::to_vec(&document).unwrap()).unwrap();
            assert!(directory.store().list().is_err(), "loaded {entry}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn saved_file_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let directory = TestDirectory::new();
        directory.store().add("Mac", "mac.local", 5900).unwrap();
        assert_eq!(
            fs::metadata(directory.0.join("connections.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}
