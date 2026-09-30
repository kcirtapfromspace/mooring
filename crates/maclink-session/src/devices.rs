//! The sharing Mac's approved devices: each Mac that paired with it, known by
//! its Noise static public key, and whether the long-lived pairing code from
//! before per-device keys is still accepted.
//!
//! Only public keys and display metadata are stored, never a secret. The file
//! follows the peer list's conventions: bounded size, strict validation,
//! owner-only permissions, atomic replacement, a cross-process lock, and never
//! overwriting a file it cannot read.

use crate::files;
use crate::pairing::{base64_decode, base64_encode, validate_name};
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::path::PathBuf;

pub(crate) const MAX_DEVICES: usize = 32;
/// At most this many Macs approved with the old code: whoever holds it can't
/// fill the list, and room stays for Macs paired with one-time codes.
pub(crate) const MAX_MIGRATED: usize = 8;
const FILE_NAME: &str = "native-devices.json";
const LOCK_NAME: &str = "native-devices.lock";
const MAX_FILE_BYTES: u64 = 64 * 1024;
/// After the first Mac moves from the old pairing code to its own key, the old
/// code keeps working this long, so every Mac paired the old way can follow.
pub(crate) const LEGACY_GRACE_SECONDS: u64 = 7 * 24 * 60 * 60;

/// Lowercase hex SHA-256 of a device's public key.
pub(crate) fn device_id(public_key: &[u8; 32]) -> String {
    Sha256::digest(public_key)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Via {
    /// Paired with a one-time code.
    Code,
    /// Moved over from the old long-lived pairing code.
    Migrated,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Device {
    pub id: String,
    pub name: String,
    #[serde(rename = "publicKey")]
    pub public_key: String,
    /// Unix seconds.
    pub paired: u64,
    #[serde(rename = "lastSeen")]
    pub last_seen: u64,
    pub via: Via,
}

impl Device {
    pub(crate) fn key(&self) -> Result<[u8; 32]> {
        let bytes = base64_decode(&self.public_key).ok_or(Error::Invalid)?;
        bytes.as_slice().try_into().map_err(|_| Error::Invalid)
    }
    fn validated(self) -> Result<Self> {
        let key = self.key()?;
        validate_name(&self.name)?;
        if self.id != device_id(&key) {
            return Err(Error::Invalid);
        }
        Ok(self)
    }
}

/// Whether Macs paired before per-device keys may still connect.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Legacy {
    pub accepted: bool,
    /// Unix seconds after which it stops, once a Mac has moved over.
    #[serde(rename = "closesAt")]
    pub closes_at: Option<u64>,
    #[serde(rename = "lastUsed")]
    pub last_used: Option<u64>,
}

impl Legacy {
    pub(crate) fn is_open(&self, now: u64) -> bool {
        self.accepted && self.closes_at.is_none_or(|closes| now < closes)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DeviceState {
    pub devices: Vec<Device>,
    pub legacy: Legacy,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    version: u32,
    devices: Vec<Device>,
    legacy: Legacy,
}

/// What Settings may do to the old pairing code.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LegacyAction {
    StopNow,
    AnotherWeek,
}

pub(crate) struct DeviceStore {
    directory: PathBuf,
}

impl DeviceStore {
    pub(crate) fn new(directory: PathBuf) -> Self {
        Self { directory }
    }
    pub(crate) fn default_location() -> Result<Self> {
        maclink_platform::support_directory()
            .map(Self::new)
            .map_err(|_| Error::Storage)
    }

    /// None when the file doesn't exist yet.
    fn read(&self) -> Result<Option<DeviceState>> {
        let Some(bytes) = files::read_bounded(&self.directory.join(FILE_NAME), MAX_FILE_BYTES)?
        else {
            return Ok(None);
        };
        let document: Document = serde_json::from_slice(&bytes).map_err(|_| Error::Storage)?;
        if document.version != 1 || document.devices.len() > MAX_DEVICES {
            return Err(Error::Storage);
        }
        let mut ids = HashSet::new();
        let devices = document
            .devices
            .into_iter()
            .map(|device| {
                let device = device.validated().map_err(|_| Error::Storage)?;
                if ids.insert(device.id.clone()) {
                    Ok(device)
                } else {
                    Err(Error::Storage)
                }
            })
            .collect::<Result<_>>()?;
        Ok(Some(DeviceState {
            devices,
            legacy: document.legacy,
        }))
    }

    /// The current state. A missing file has no devices and doesn't accept
    /// the old code; `init` decides what an upgrade starts with.
    pub(crate) fn load(&self) -> Result<DeviceState> {
        Ok(self.read()?.unwrap_or_default())
    }

    fn save(&self, state: &DeviceState) -> Result<()> {
        let document = Document {
            version: 1,
            devices: state.devices.clone(),
            legacy: state.legacy,
        };
        let mut bytes = serde_json::to_vec_pretty(&document).map_err(|_| Error::Internal)?;
        bytes.push(b'\n');
        files::write_atomic(&self.directory, FILE_NAME, &bytes)
    }

    /// Changes the state under the cross-process lock.
    fn update<T>(&self, change: impl FnOnce(&mut DeviceState) -> Result<T>) -> Result<T> {
        let _lock = files::lock(&self.directory, LOCK_NAME)?;
        let mut state = self.load()?;
        let result = change(&mut state)?;
        self.save(&state)?;
        Ok(result)
    }

    /// Creates the file if it doesn't exist. A Mac that already shared before
    /// this version keeps accepting its old code, so its paired Macs can move
    /// over; a new sharing identity never does.
    pub(crate) fn init(&self, accept_old_code: bool) -> Result<()> {
        let _lock = files::lock(&self.directory, LOCK_NAME)?;
        if self.read()?.is_some() {
            return Ok(());
        }
        self.save(&DeviceState {
            devices: vec![],
            legacy: Legacy {
                accepted: accept_old_code,
                ..Legacy::default()
            },
        })
    }

    /// The approved device with this key, if any.
    pub(crate) fn approved(&self, public_key: &[u8; 32]) -> Result<Option<Device>> {
        let id = device_id(public_key);
        Ok(self
            .load()?
            .devices
            .into_iter()
            .find(|device| device.id == id))
    }

    /// Adds or refreshes a device after it proved a one-time code or the old
    /// code. The old code approves only while it is still accepted, checked
    /// under the lock, and the first move-over starts its grace period.
    pub(crate) fn approve(
        &self,
        public_key: &[u8; 32],
        name: &str,
        via: Via,
        now: u64,
    ) -> Result<String> {
        validate_name(name)?;
        let id = device_id(public_key);
        self.update(|state| {
            if via == Via::Migrated && !state.legacy.is_open(now) {
                return Err(Error::Auth);
            }
            state.devices.retain(|device| device.id != id);
            let migrated = state
                .devices
                .iter()
                .filter(|device| device.via == Via::Migrated)
                .count();
            if state.devices.len() >= MAX_DEVICES
                || (via == Via::Migrated && migrated >= MAX_MIGRATED)
            {
                return Err(Error::Busy);
            }
            state.devices.push(Device {
                id: id.clone(),
                name: name.to_owned(),
                public_key: base64_encode(public_key),
                paired: now,
                last_seen: now,
                via,
            });
            if via == Via::Migrated && state.legacy.closes_at.is_none() {
                state.legacy.closes_at = Some(now.saturating_add(LEGACY_GRACE_SECONDS));
            }
            Ok(id.clone())
        })
    }

    /// Notes an approved device's connection and its current name.
    pub(crate) fn seen(&self, id: &str, name: &str, now: u64) -> Result<()> {
        validate_name(name)?;
        self.update(|state| {
            let device = state
                .devices
                .iter_mut()
                .find(|device| device.id == id)
                .ok_or(Error::Auth)?;
            device.last_seen = now;
            device.name = name.to_owned();
            Ok(())
        })
    }

    pub(crate) fn old_code_used(&self, now: u64) -> Result<()> {
        self.update(|state| {
            state.legacy.last_used = Some(now);
            Ok(())
        })
    }

    /// Returns whether the device was approved.
    pub(crate) fn remove(&self, id: &str) -> Result<bool> {
        self.update(|state| {
            let before = state.devices.len();
            state.devices.retain(|device| device.id != id);
            Ok(state.devices.len() != before)
        })
    }

    pub(crate) fn legacy_action(&self, action: LegacyAction, now: u64) -> Result<()> {
        self.update(|state| {
            match action {
                LegacyAction::StopNow => state.legacy.accepted = false,
                // Once past its end, the old code stays stopped.
                LegacyAction::AnotherWeek if state.legacy.is_open(now) => {
                    state.legacy.closes_at = Some(now.saturating_add(LEGACY_GRACE_SECONDS));
                }
                LegacyAction::AnotherWeek => return Err(Error::Invalid),
            }
            Ok(())
        })
    }

    /// Reset Pairing: a new sharing identity approves no one.
    pub(crate) fn reset(&self) -> Result<()> {
        let _lock = files::lock(&self.directory, LOCK_NAME)?;
        self.save(&DeviceState::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    pub(crate) struct Directory(pub PathBuf);
    impl Directory {
        pub(crate) fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "maclink-devices-{}-{}",
                std::process::id(),
                files::next_sequence()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn store(&self) -> DeviceStore {
            DeviceStore::new(self.0.clone())
        }
    }
    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    const NOW: u64 = 1_790_000_000;

    #[test]
    fn devices_are_approved_refreshed_and_removed_by_key() {
        let directory = Directory::new();
        let store = directory.store();
        assert_eq!(store.load().unwrap(), DeviceState::default());
        let id = store
            .approve(&[1; 32], "MacBook Pro", Via::Code, NOW)
            .unwrap();
        assert_eq!(id, device_id(&[1; 32]));
        assert_eq!(
            store.approved(&[1; 32]).unwrap().unwrap().name,
            "MacBook Pro"
        );
        assert!(store.approved(&[2; 32]).unwrap().is_none());
        store.seen(&id, "Pat's MacBook Pro", NOW + 5).unwrap();
        let device = store.approved(&[1; 32]).unwrap().unwrap();
        assert_eq!(
            (device.name.as_str(), device.paired, device.last_seen),
            ("Pat's MacBook Pro", NOW, NOW + 5)
        );
        assert_eq!(
            store.seen(&device_id(&[3; 32]), "Other", NOW),
            Err(Error::Auth)
        );
        // Pairing again replaces rather than duplicates.
        store
            .approve(&[1; 32], "MacBook Pro", Via::Code, NOW + 9)
            .unwrap();
        assert_eq!(store.load().unwrap().devices.len(), 1);
        assert!(store.remove(&id).unwrap());
        assert!(!store.remove(&id).unwrap());
        assert!(store.approved(&[1; 32]).unwrap().is_none());
        assert_eq!(
            store.approve(&[1; 32], "Bad\nName", Via::Code, NOW),
            Err(Error::Invalid)
        );
    }

    #[test]
    fn the_old_code_closes_a_week_after_the_first_move_over() {
        let directory = Directory::new();
        let store = directory.store();
        // An upgrade keeps accepting the old code; a later init changes nothing.
        store.init(true).unwrap();
        store.init(false).unwrap();
        let state = store.load().unwrap();
        assert!(state.legacy.is_open(NOW) && state.legacy.closes_at.is_none());
        store.old_code_used(NOW).unwrap();
        assert_eq!(store.load().unwrap().legacy.last_used, Some(NOW));
        store
            .approve(&[1; 32], "MacBook Pro", Via::Migrated, NOW)
            .unwrap();
        store
            .approve(&[2; 32], "iMac", Via::Migrated, NOW + 100)
            .unwrap();
        let legacy = store.load().unwrap().legacy;
        assert_eq!(
            legacy.closes_at,
            Some(NOW + LEGACY_GRACE_SECONDS),
            "the first move-over starts it"
        );
        assert!(legacy.is_open(NOW + LEGACY_GRACE_SECONDS - 1));
        assert!(!legacy.is_open(NOW + LEGACY_GRACE_SECONDS));
        store
            .legacy_action(LegacyAction::AnotherWeek, NOW + LEGACY_GRACE_SECONDS - 10)
            .unwrap();
        assert!(
            store
                .load()
                .unwrap()
                .legacy
                .is_open(NOW + LEGACY_GRACE_SECONDS + 100)
        );
        assert_eq!(
            store.legacy_action(LegacyAction::AnotherWeek, NOW + 30 * LEGACY_GRACE_SECONDS),
            Err(Error::Invalid),
            "past its end, it stays stopped"
        );
        store.legacy_action(LegacyAction::StopNow, NOW).unwrap();
        assert!(!store.load().unwrap().legacy.is_open(NOW));
        assert_eq!(
            store.approve(&[3; 32], "Late Mac", Via::Migrated, NOW),
            Err(Error::Auth),
            "a move-over that finishes after Stop Now approves no one"
        );
        assert_eq!(
            store.legacy_action(LegacyAction::AnotherWeek, NOW),
            Err(Error::Invalid),
            "stopped is final"
        );
        // A fresh identity never accepts it, and Reset Pairing approves no one.
        let fresh = Directory::new();
        fresh.store().init(false).unwrap();
        assert!(!fresh.store().load().unwrap().legacy.is_open(NOW));
        store.reset().unwrap();
        assert_eq!(store.load().unwrap(), DeviceState::default());
    }

    #[test]
    fn the_old_code_approves_at_most_eight_macs() {
        let directory = Directory::new();
        let store = directory.store();
        store.init(true).unwrap();
        for index in 0..MAX_MIGRATED {
            store
                .approve(&[index as u8 + 1; 32], "Mac", Via::Migrated, NOW)
                .unwrap();
        }
        assert_eq!(
            store.approve(&[100; 32], "Mac", Via::Migrated, NOW),
            Err(Error::Busy)
        );
        // Moving over again replaces, and one-time codes still have room.
        store.approve(&[1; 32], "Mac", Via::Migrated, NOW).unwrap();
        store.approve(&[100; 32], "Mac", Via::Code, NOW).unwrap();
        assert_eq!(store.load().unwrap().devices.len(), MAX_MIGRATED + 1);
    }

    #[test]
    fn the_file_is_owner_only_bounded_and_strict() {
        use std::os::unix::fs::PermissionsExt;
        let directory = Directory::new();
        let store = directory.store();
        store
            .approve(&[1; 32], "MacBook Pro", Via::Code, NOW)
            .unwrap();
        let path = directory.0.join(FILE_NAME);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let text = fs::read_to_string(&path).unwrap();
        assert!(!text.contains("secret") && !text.contains("private"));
        for _ in 1..MAX_DEVICES {
            let key = [store.load().unwrap().devices.len() as u8 + 1; 32];
            store.approve(&key, "Mac", Via::Code, NOW).unwrap();
        }
        assert_eq!(
            store.approve(&[200; 32], "One too many", Via::Code, NOW),
            Err(Error::Busy)
        );
        let good = fs::read_to_string(&path).unwrap();
        for bad in [
            good.replace("\"version\": 1", "\"version\": 2"),
            good.replacen(&device_id(&[1; 32]), &device_id(&[9; 32]), 1),
            good.replacen("\"via\": \"code\"", "\"via\": \"other\"", 1),
            good.replacen("\"accepted\"", "\"accepted\": true, \"extra\"", 1),
            "{invalid".into(),
        ] {
            fs::write(&path, &bad).unwrap();
            assert_eq!(store.load(), Err(Error::Storage), "{:.60}", bad);
            assert_eq!(
                store.approve(&[1; 32], "Mac", Via::Code, NOW),
                Err(Error::Storage),
                "never overwrites"
            );
            assert_eq!(fs::read_to_string(&path).unwrap(), bad);
        }
    }
}
