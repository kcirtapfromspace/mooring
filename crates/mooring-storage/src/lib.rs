//! File-system adapters. No UI, protocol, SSH process or session ownership.
pub mod catalog;
use std::path::PathBuf;
/// The app's owner-only local telemetry socket, relative to the data directory.
/// It lives in its own 0700 folder so no other user can reach it.
pub const TELEMETRY_SOCKET: &str = "telemetry/telemetry.sock";

/// Shared by the CLI and native session. Existing installations keep their
/// data directory so other running copies still use the same store and lock.
pub fn support_directory() -> Result<PathBuf, String> {
    support_directory_for(
        std::env::var_os("MOORING_HOME"),
        std::env::var_os("MACLINK_HOME"),
        std::env::var_os("HOME"),
    )
}

fn support_directory_for(
    override_path: Option<std::ffi::OsString>,
    legacy_override: Option<std::ffi::OsString>,
    home: Option<std::ffi::OsString>,
) -> Result<PathBuf, String> {
    if let Some(path) = override_path.or(legacy_override) {
        if path.is_empty() {
            return Err("MOORING_HOME must not be empty".into());
        }
        return Ok(PathBuf::from(path));
    }
    let base = PathBuf::from(home.ok_or("HOME is unavailable; set MOORING_HOME")?)
        .join("Library/Application Support");
    let existing = base.join("MacLink"); // Stable storage for previously paired Macs.
    Ok(if existing.exists() {
        existing
    } else {
        base.join("Mooring")
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn branding_preserves_existing_storage_and_explicit_overrides() {
        let home = std::env::temp_dir().join(format!("mooring-storage-{}", std::process::id()));
        std::fs::create_dir_all(&home).unwrap();
        let select = |current, legacy| {
            support_directory_for(current, legacy, Some(home.clone().into_os_string()))
        };
        let base = home.join("Library/Application Support");
        assert_eq!(select(None, None).unwrap(), base.join("Mooring"));
        let existing = base.join("MacLink");
        std::fs::create_dir_all(&existing).unwrap();
        std::fs::write(existing.join("connections.json"), b"saved connections").unwrap();
        assert_eq!(select(None, None).unwrap(), existing);
        assert_eq!(
            std::fs::read(existing.join("connections.json")).unwrap(),
            b"saved connections"
        );
        assert_eq!(
            select(Some("new".into()), Some("old".into())).unwrap(),
            PathBuf::from("new")
        );
        assert_eq!(
            select(None, Some("old".into())).unwrap(),
            PathBuf::from("old")
        );
        assert!(select(Some("".into()), Some("old".into())).is_err());
        assert!(support_directory_for(None, None, None).is_err());
        std::fs::remove_dir_all(home).unwrap();
    }
}
