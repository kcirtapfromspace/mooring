//! Out-of-band pairing codes and saved peer credentials, in three kinds.
//!
//! - An old code, `MLP1.` + standard padded base64 of a JSON object with
//!   exactly `version` (1), `address`, `name`, `publicKey` and `secret` (both
//!   base64 of 32 bytes). The secret is the sharing Mac's long-lived pairing
//!   PSK. Keychain credentials from before per-device keys hold the same JSON
//!   without the envelope, so they remain readable.
//! - A one-time code, `MLP2.` and the same fields with `version` 2, plus an
//!   optional `addresses` list: the sharing Mac's other addresses, so a viewer
//!   away from its home network can still reach it. Its secret approves one
//!   new Mac within minutes; it is never saved.
//! - A saved pairing for an approved Mac: `version` 3 without a secret. The
//!   viewer's own device key proves who it is.
//!
//! Intermediate copies of a secret are zeroized and Debug output omits it.

use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

pub(crate) const MAX_NAME_BYTES: usize = 160;
const PREFIX: &str = "MLP1.";
const ONE_TIME_PREFIX: &str = "MLP2.";
const MAX_CODE_TEXT: usize = 2048;
/// Base64 makes this at most 2000 characters, which with the prefix fits
/// MAX_CODE_TEXT.
const MAX_CODE_JSON: usize = 1500;
/// A code or saved Mac lists at most this many addresses: the main one and up
/// to seven others.
pub(crate) const MAX_ADDRESSES: usize = 8;
/// The other addresses, joined by single spaces, fit the C structs' field.
pub(crate) const MAX_ALTERNATES_TEXT: usize = 1023;
const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Control (Cc) and format (Cf) characters, including bidirectional overrides
/// and zero-width joiners that could disguise a peer's displayed name.
fn is_hidden(character: char) -> bool {
    character.is_control()
        || matches!(character as u32,
            0x00AD | 0x0600..=0x0605 | 0x061C | 0x06DD | 0x070F | 0x0890..=0x0891 | 0x08E2
            | 0x180E | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F
            | 0xFEFF | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD | 0x13430..=0x1343F
            | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F)
}

pub(crate) fn validate_name(name: &str) -> Result<()> {
    if name.is_empty() || name.len() > MAX_NAME_BYTES || name.chars().any(is_hidden) {
        return Err(Error::Invalid);
    }
    Ok(())
}

/// Turn the local computer name into a valid display name rather than failing.
pub(crate) fn local_name(raw: &str) -> String {
    let visible: String = raw
        .chars()
        .filter(|character| !is_hidden(*character))
        .collect();
    let mut name = String::new();
    for character in visible.trim().chars() {
        if name.len() + character.len_utf8() > MAX_NAME_BYTES {
            break;
        }
        name.push(character);
    }
    let name = name.trim_end().to_owned();
    if name.is_empty() { "Mac".into() } else { name }
}

/// The project's single host rule: DNS names, IPv4 and IPv6, never URLs,
/// credentials, ports, scoped addresses or legacy numeric IPv4 spellings.
pub(crate) fn normalize_address(address: &str) -> Result<String> {
    maclink_platform::validate_host(address).map_err(|_| Error::Invalid)
}

pub(crate) fn base64_encode(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let value = chunk
            .iter()
            .enumerate()
            .fold(0_u32, |value, (index, byte)| {
                value | u32::from(*byte) << (16 - index * 8)
            });
        for index in 0..4 {
            if index <= chunk.len() {
                text.push(BASE64[(value >> (18 - index * 6)) as usize & 63] as char);
            } else {
                text.push('=');
            }
        }
    }
    text
}

/// Strict standard base64: required padding and zero unused bits.
pub(crate) fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut output = Vec::with_capacity(bytes.len() / 4 * 3);
    for (group, chunk) in bytes.chunks(4).enumerate() {
        let last = group == bytes.len() / 4 - 1;
        let padding = chunk.iter().rev().take_while(|byte| **byte == b'=').count();
        if padding > 2 || (padding > 0 && !last) {
            return None;
        }
        let mut value = 0_u32;
        for (index, byte) in chunk[..4 - padding].iter().enumerate() {
            let digit = BASE64.iter().position(|candidate| candidate == byte)? as u32;
            value |= digit << (18 - index * 6);
        }
        let produced = 3 - padding;
        if value & ((1 << (8 * (3 - produced))) - 1) != 0 {
            return None;
        }
        output.extend((0..produced).map(|index| (value >> (16 - index * 8)) as u8));
    }
    Some(output)
}

fn key(text: &str) -> Result<[u8; 32]> {
    let mut bytes = Zeroizing::new(base64_decode(text).ok_or(Error::Invalid)?);
    let key: [u8; 32] = bytes.as_slice().try_into().map_err(|_| Error::Invalid)?;
    bytes.zeroize();
    Ok(key)
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Wire {
    version: u32,
    address: String,
    name: String,
    #[serde(rename = "publicKey")]
    public_key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    secret: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    addresses: Vec<String>,
}
impl Drop for Wire {
    fn drop(&mut self) {
        if let Some(secret) = self.secret.as_mut() {
            secret.zeroize();
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub(crate) enum CodeKind {
    /// From before per-device keys: the secret is the sharing Mac's
    /// long-lived pairing secret.
    Legacy = 1,
    /// Approves one new Mac, briefly; never saved.
    OneTime = 2,
    /// A saved pairing for an approved Mac, without a secret.
    Device = 3,
}
impl CodeKind {
    pub(crate) fn from_raw(value: u8) -> Result<Self> {
        match value {
            1 => Ok(Self::Legacy),
            2 => Ok(Self::OneTime),
            3 => Ok(Self::Device),
            _ => Err(Error::Invalid),
        }
    }
}

/// The other addresses of a Mac whose main one is `primary`: each valid by the
/// host rule and normalized, none repeated or equal to `primary`, at most
/// seven, and short enough to join.
pub(crate) fn checked_alternates(primary: &str, list: &[String]) -> Result<Vec<String>> {
    let mut checked: Vec<String> = Vec::with_capacity(list.len());
    for entry in list {
        let address = normalize_address(entry)?;
        if address == primary || checked.contains(&address) {
            return Err(Error::Invalid);
        }
        checked.push(address);
    }
    if checked.len() >= MAX_ADDRESSES || joined_length(&checked) > MAX_ALTERNATES_TEXT {
        return Err(Error::Invalid);
    }
    Ok(checked)
}
/// As checked_alternates, but drops what doesn't qualify instead of failing:
/// for this Mac's own list.
pub(crate) fn fitted_alternates(primary: &str, list: &[String]) -> Vec<String> {
    let mut fitted: Vec<String> = Vec::new();
    for entry in list {
        let Ok(address) = normalize_address(entry) else {
            continue;
        };
        if address == primary || fitted.contains(&address) || fitted.len() + 1 >= MAX_ADDRESSES {
            continue;
        }
        fitted.push(address);
        if joined_length(&fitted) > MAX_ALTERNATES_TEXT {
            fitted.pop();
        }
    }
    fitted
}
fn joined_length(list: &[String]) -> usize {
    list.iter().map(String::len).sum::<usize>() + list.len().saturating_sub(1)
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct PairingCode {
    pub address: String,
    /// Other addresses of the same Mac, tried with `address`; never saved
    /// in Keychain.
    pub alternates: Vec<String>,
    pub name: String,
    pub public_key: [u8; 32],
    /// All zero for a device pairing.
    pub secret: [u8; 32],
    pub kind: CodeKind,
}
impl Drop for PairingCode {
    fn drop(&mut self) {
        self.secret.zeroize();
    }
}
impl std::fmt::Debug for PairingCode {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("PairingCode")
            .field("address", &self.address)
            .field("alternates", &self.alternates)
            .field("name", &self.name)
            .field("peer_id", &self.peer_id())
            .field("kind", &self.kind)
            .finish_non_exhaustive()
    }
}

impl PairingCode {
    /// An old code or credential, for tests.
    #[cfg(test)]
    pub(crate) fn new(
        address: &str,
        name: &str,
        public_key: [u8; 32],
        secret: [u8; 32],
    ) -> Result<Self> {
        Self::of_kind(address, name, public_key, secret, CodeKind::Legacy)
    }
    /// A device pairing carries no secret: all zero.
    pub(crate) fn of_kind(
        address: &str,
        name: &str,
        public_key: [u8; 32],
        secret: [u8; 32],
        kind: CodeKind,
    ) -> Result<Self> {
        validate_name(name)?;
        if (kind == CodeKind::Device) != (secret == [0; 32]) {
            return Err(Error::Invalid);
        }
        Ok(Self {
            address: normalize_address(address)?,
            alternates: vec![],
            name: name.to_owned(),
            public_key,
            secret,
            kind,
        })
    }
    /// The same code listing `alternates` too, checked strictly.
    pub(crate) fn with_alternates(mut self, alternates: &[String]) -> Result<Self> {
        self.alternates = checked_alternates(&self.address, alternates)?;
        Ok(self)
    }
    /// Every address, the main one first.
    pub(crate) fn addresses(&self) -> Vec<String> {
        std::iter::once(self.address.clone())
            .chain(self.alternates.iter().cloned())
            .collect()
    }
    /// The saved pairing once this Mac's device key is approved: the same
    /// sharing Mac, without a secret.
    pub(crate) fn device(&self) -> Self {
        Self {
            address: self.address.clone(),
            alternates: self.alternates.clone(),
            name: self.name.clone(),
            public_key: self.public_key,
            secret: [0; 32],
            kind: CodeKind::Device,
        }
    }

    /// For the sharing Mac's own code: the computer name is normalized, and
    /// of its other addresses, those that don't qualify or fit are left out.
    pub(crate) fn for_host(
        address: &str,
        computer_name: &str,
        public_key: [u8; 32],
        secret: [u8; 32],
        kind: CodeKind,
        alternates: &[String],
    ) -> Result<Self> {
        if kind == CodeKind::Device {
            return Err(Error::Invalid);
        }
        let mut code = Self::of_kind(
            address,
            &local_name(computer_name),
            public_key,
            secret,
            kind,
        )?;
        code.alternates = fitted_alternates(&code.address, alternates);
        Ok(code)
    }

    /// Lowercase hex SHA-256 of the public key: no secret, name or address.
    pub(crate) fn peer_id(&self) -> String {
        Sha256::digest(self.public_key)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }

    /// Only a one-time code lists the other addresses.
    fn json(&self, version: u32) -> Zeroizing<Vec<u8>> {
        let wire = Wire {
            version,
            address: self.address.clone(),
            name: self.name.clone(),
            public_key: base64_encode(&self.public_key),
            secret: (self.kind != CodeKind::Device).then(|| base64_encode(&self.secret)),
            addresses: if version == 2 {
                self.alternates.clone()
            } else {
                vec![]
            },
        };
        Zeroizing::new(
            serde_json::to_vec(&wire).expect("pairing JSON has only string and integer fields"),
        )
    }
    /// Parses JSON of exactly `version` into a code of `kind`.
    fn from_json(bytes: &[u8], version: u32, kind: CodeKind) -> Result<Self> {
        if bytes.len() > MAX_CODE_JSON {
            return Err(Error::Invalid);
        }
        let wire: Wire = serde_json::from_slice(bytes).map_err(|_| Error::Invalid)?;
        if wire.version != version || (version != 2 && !wire.addresses.is_empty()) {
            return Err(Error::Invalid);
        }
        let secret = match (kind, wire.secret.as_deref()) {
            (CodeKind::Device, None) => [0; 32],
            (CodeKind::Legacy | CodeKind::OneTime, Some(secret)) => key(secret)?,
            _ => return Err(Error::Invalid),
        };
        Self::of_kind(
            &wire.address,
            &wire.name,
            key(&wire.public_key)?,
            secret,
            kind,
        )?
        .with_alternates(&wire.addresses)
    }

    /// The JSON stored in Keychain: version 1 for an old pairing, 3 for a
    /// device pairing. A one-time code is never stored.
    pub(crate) fn credential(&self) -> Result<Zeroizing<Vec<u8>>> {
        match self.kind {
            CodeKind::Legacy => Ok(self.json(1)),
            CodeKind::Device => Ok(self.json(3)),
            CodeKind::OneTime => Err(Error::Invalid),
        }
    }

    pub(crate) fn from_credential(bytes: &[u8]) -> Result<Self> {
        Self::from_json(bytes, 1, CodeKind::Legacy)
            .or_else(|_| Self::from_json(bytes, 3, CodeKind::Device))
    }

    /// The text a person copies: `MLP1.` for an old code, `MLP2.` for a
    /// one-time code. A device pairing is not a code.
    pub(crate) fn encode(&self) -> Result<Zeroizing<String>> {
        let (prefix, version) = match self.kind {
            CodeKind::Legacy => (PREFIX, 1),
            CodeKind::OneTime => (ONE_TIME_PREFIX, 2),
            CodeKind::Device => return Err(Error::Invalid),
        };
        let json = self.json(version);
        if json.len() > MAX_CODE_JSON {
            return Err(Error::Invalid);
        }
        let payload = Zeroizing::new(base64_encode(&json));
        Ok(Zeroizing::new(prefix.to_owned() + &payload))
    }

    pub(crate) fn parse(text: &str) -> Result<Self> {
        let text = text.trim();
        if text.len() > MAX_CODE_TEXT {
            return Err(Error::Invalid);
        }
        let (payload, version, kind) = if let Some(payload) = text.strip_prefix(PREFIX) {
            (payload, 1, CodeKind::Legacy)
        } else if let Some(payload) = text.strip_prefix(ONE_TIME_PREFIX) {
            (payload, 2, CodeKind::OneTime)
        } else {
            return Err(Error::Invalid);
        };
        let json = Zeroizing::new(base64_decode(payload).ok_or(Error::Invalid)?);
        Self::from_json(&json, version, kind)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use serde_json::{Value, json};

    pub(crate) fn code() -> PairingCode {
        let public = std::array::from_fn(|index| index as u8 + 1);
        let secret = std::array::from_fn(|index| index as u8 + 101);
        PairingCode::new("studio.local", "Studio Mac", public, secret).unwrap()
    }
    fn envelope(object: &Value) -> String {
        PREFIX.to_owned() + &base64_encode(&serde_json::to_vec(object).unwrap())
    }

    #[test]
    fn base64_is_standard_padded_and_canonical() {
        for (plain, encoded) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(base64_encode(plain.as_bytes()), encoded);
            assert_eq!(base64_decode(encoded).unwrap(), plain.as_bytes());
        }
        let bytes: Vec<u8> = (0..=255).collect();
        assert_eq!(base64_decode(&base64_encode(&bytes)).unwrap(), bytes);
        for invalid in [
            "Zg",
            "Zg=",
            "Zg===",
            "Z===",
            "Zh==",
            "Zm9=",
            "Zg==Zg==",
            "Zm9v\n",
            "Zm-v",
            "Zm_v",
            "not base64!",
        ] {
            assert!(base64_decode(invalid).is_none(), "{invalid}");
        }
    }

    #[test]
    fn codes_round_trip_and_identify_only_the_public_key() {
        let original = code();
        let parsed = PairingCode::parse(&format!(
            " \n\t{}\r\n ",
            original.encode().unwrap().as_str()
        ))
        .unwrap();
        assert_eq!(parsed, original);
        assert_eq!(
            PairingCode::from_credential(&original.credential().unwrap()).unwrap(),
            original
        );
        let id = original.peer_id();
        assert_eq!(id.len(), 64);
        assert!(
            id.bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        );
        let renamed = PairingCode::new(
            "192.168.1.25",
            "Renamed Mac",
            original.public_key,
            [255; 32],
        )
        .unwrap();
        assert_eq!(renamed.peer_id(), id, "no secret, name or address material");
        let other =
            PairingCode::new("studio.local", "Studio Mac", [42; 32], original.secret).unwrap();
        assert_ne!(other.peer_id(), id);
        assert!(
            !format!("{original:?}").contains(&base64_encode(&original.secret)),
            "Debug omits the secret"
        );
    }

    #[test]
    fn credentials_from_the_earlier_swift_encoder_remain_readable() {
        // Foundation's JSONEncoder escapes "/" and does not fix key order.
        let original = code();
        let legacy = format!(
            r#"{{"secret":"{}","name":"Studio Mac","publicKey":"{}","address":"studio.local","version":1}}"#,
            base64_encode(&original.secret).replace('/', "\\/"),
            base64_encode(&original.public_key).replace('/', "\\/"),
        );
        assert_eq!(
            PairingCode::from_credential(legacy.as_bytes()).unwrap(),
            original
        );
    }

    #[test]
    fn one_time_codes_list_other_addresses_strictly_and_within_size() {
        let host = code();
        let long: Vec<String> = (0..7)
            .map(|index| {
                let label = "a".repeat(63);
                format!("{label}.{label}.{label}.{}{index}.example", "b".repeat(30))
            })
            .collect();
        let once = PairingCode::for_host(
            "studio.local",
            "S".repeat(MAX_NAME_BYTES).as_str(),
            host.public_key,
            [9; 32],
            CodeKind::OneTime,
            &long,
        )
        .unwrap();
        assert!(!once.alternates.is_empty() && once.alternates.len() < long.len());
        assert!(once.alternates.join(" ").len() <= MAX_ALTERNATES_TEXT);
        let text = once.encode().unwrap();
        assert!(text.len() <= MAX_CODE_TEXT);
        assert_eq!(
            PairingCode::parse(&text).unwrap().alternates,
            once.alternates
        );

        let listed = |addresses: Value| {
            let mut object: Value = serde_json::from_slice(&once.json(2)).unwrap();
            object["addresses"] = addresses;
            ONE_TIME_PREFIX.to_owned() + &base64_encode(&serde_json::to_vec(&object).unwrap())
        };
        let good = PairingCode::parse(&listed(json!(["192.168.25.201", "100.122.9.8"]))).unwrap();
        assert_eq!(
            good.addresses(),
            ["studio.local", "192.168.25.201", "100.122.9.8"]
        );
        for bad in [
            json!(["vnc://studio.local"]),
            json!(["studio.local"]),
            json!(["10.0.0.1", "10.0.0.1"]),
            json!(
                (1..=8)
                    .map(|index| format!("10.0.0.{index}"))
                    .collect::<Vec<_>>()
            ),
            json!("10.0.0.1"),
            json!([1]),
        ] {
            assert_eq!(
                PairingCode::parse(&listed(bad.clone())),
                Err(Error::Invalid),
                "{bad}"
            );
        }
        // Old codes and saved pairings never list them.
        let mut object: Value = serde_json::from_slice(&host.credential().unwrap()).unwrap();
        object["addresses"] = json!(["10.0.0.1"]);
        assert_eq!(
            PairingCode::from_credential(&serde_json::to_vec(&object).unwrap()),
            Err(Error::Invalid)
        );
        let saved = good.device();
        assert_eq!(saved.alternates, good.alternates);
        let stored = String::from_utf8(saved.credential().unwrap().to_vec()).unwrap();
        assert!(!stored.contains("addresses"));
    }

    #[test]
    fn one_time_codes_and_device_pairings_have_their_own_forms() {
        let host = code();
        let once = PairingCode::for_host(
            "studio.local",
            "Studio Mac",
            host.public_key,
            [9; 32],
            CodeKind::OneTime,
            &[],
        )
        .unwrap();
        let text = once.encode().unwrap();
        assert!(text.starts_with("MLP2."));
        assert_eq!(PairingCode::parse(&text).unwrap(), once);
        assert_eq!(
            once.credential(),
            Err(Error::Invalid),
            "a one-time code is never saved"
        );
        // Once approved, the saved pairing has no secret and is not a code.
        let device = once.device();
        assert_eq!(
            (device.kind, device.secret, device.peer_id()),
            (CodeKind::Device, [0; 32], once.peer_id())
        );
        let saved = device.credential().unwrap();
        let json: Value = serde_json::from_slice(&saved).unwrap();
        assert_eq!(json["version"], 3);
        assert!(json.get("secret").is_none());
        assert_eq!(PairingCode::from_credential(&saved).unwrap(), device);
        assert_eq!(device.encode(), Err(Error::Invalid));
        // Old credentials still read as old pairings.
        assert_eq!(
            PairingCode::from_credential(&host.credential().unwrap())
                .unwrap()
                .kind,
            CodeKind::Legacy
        );
        // Kinds and secrets must agree, and envelopes and versions must match.
        assert_eq!(
            PairingCode::of_kind("studio.local", "Mac", [1; 32], [0; 32], CodeKind::OneTime),
            Err(Error::Invalid)
        );
        assert_eq!(
            PairingCode::of_kind("studio.local", "Mac", [1; 32], [5; 32], CodeKind::Device),
            Err(Error::Invalid)
        );
        assert_eq!(
            PairingCode::for_host(
                "studio.local",
                "Mac",
                [1; 32],
                [0; 32],
                CodeKind::Device,
                &[]
            ),
            Err(Error::Invalid)
        );
        let mut object: Value = serde_json::from_slice(&host.credential().unwrap()).unwrap();
        object["version"] = json!(2);
        assert!(
            PairingCode::parse(&envelope(&object)).is_err(),
            "MLP1 carries version 1 only"
        );
        assert!(
            PairingCode::from_credential(&serde_json::to_vec(&object).unwrap()).is_err(),
            "a one-time code is never a credential"
        );
        let mut device_json = json.clone();
        device_json["secret"] = json!(base64_encode(&[5; 32]));
        assert!(
            PairingCode::from_credential(&serde_json::to_vec(&device_json).unwrap()).is_err(),
            "a device pairing has no secret"
        );
        let one_time_payload = &text["MLP2.".len()..];
        assert!(PairingCode::parse(&format!("MLP1.{one_time_payload}")).is_err());
    }

    #[test]
    fn addresses_use_the_shared_strict_host_rule() {
        for (address, normalized) in [
            ("studio.local", "studio.local"),
            ("STUDIO.local.", "studio.local."),
            ("192.168.1.25", "192.168.1.25"),
            ("100.64.0.1", "100.64.0.1"),
            ("::1", "::1"),
            ("[::1]", "::1"),
            ("2001:db8::1", "2001:db8::1"),
            ("mac-studio", "mac-studio"),
            ("a", "a"),
        ] {
            assert_eq!(normalize_address(address).unwrap(), normalized);
        }
        let maximum = [
            "a".repeat(63),
            "b".repeat(63),
            "c".repeat(63),
            "d".repeat(61),
        ]
        .join(".");
        assert_eq!(maximum.len(), 253);
        assert!(normalize_address(&maximum).is_ok());
        for address in [
            "",
            "vnc://studio.local",
            "https://studio.local",
            "user@studio.local",
            "studio.local/path",
            "studio.local?token=1",
            "studio local",
            "studio.local\n",
            "fe80::1%en0",
            "büro.local",
            "host;open",
            &"a".repeat(254),
            ".",
            "-",
            "a..b",
            "-mac.local",
            "mac-.local",
            "host:5900",
            &("a".repeat(64) + ".local"),
            "127.1",
            "127.000.0.1",
            "0177.0.0.1",
            "999.999.999.999",
            "0x7f000001",
            "0x7f.0.0.1",
            "4294967295",
            "::1\0junk",
            "127.0.0.1\0junk",
        ] {
            assert!(normalize_address(address).is_err(), "{address:?}");
        }
    }

    #[test]
    fn names_are_bounded_utf8_without_hidden_characters() {
        let maximum = "é".repeat(80);
        assert_eq!(maximum.len(), MAX_NAME_BYTES);
        let long = PairingCode::new("studio.local", &maximum, [1; 32], [2; 32]).unwrap();
        assert_eq!(
            PairingCode::parse(&long.encode().unwrap()).unwrap().name,
            maximum
        );
        for name in [
            "",
            "Mac\nInjected",
            "Mac\0Injected",
            "Mac\u{202e}caM",
            "A\u{200d}B",
            &"é".repeat(81),
        ] {
            assert!(validate_name(name).is_err(), "{name:?}");
        }
        assert_eq!(
            local_name("  Pat’s 👩\u{200d}💻 Mac\u{202e}\n "),
            "Pat’s 👩💻 Mac"
        );
        assert_eq!(local_name("\u{200b}\n"), "Mac");
        let truncated = local_name(&"é".repeat(100));
        assert_eq!(
            (truncated.len(), truncated.chars().count()),
            (MAX_NAME_BYTES, 80)
        );
        assert!(
            PairingCode::for_host(
                "studio.local",
                "A\u{200d}B",
                [1; 32],
                [2; 32],
                CodeKind::Legacy,
                &[]
            )
            .is_ok()
        );
    }

    #[test]
    fn parser_rejects_every_invalid_field_and_envelope() {
        let original = code();
        let object: Value = serde_json::from_slice(&original.credential().unwrap()).unwrap();
        let replacements = [
            ("version", json!(0)),
            ("version", json!(2)),
            ("version", json!("1")),
            ("version", json!(1.0)),
            ("version", json!(-1)),
            ("name", json!("")),
            ("name", json!("Mac\nInjected")),
            ("name", json!("Mac\u{0}Injected")),
            ("name", json!("é".repeat(81))),
            ("address", json!("")),
            ("address", json!("studio.local/remote")),
            ("address", json!("x".repeat(254))),
            ("secret", json!(base64_encode(&[1; 31]))),
            ("secret", json!(base64_encode(&[1; 33]))),
            ("secret", json!("not base64!")),
            ("publicKey", json!(base64_encode(&[2; 31]))),
            ("publicKey", json!(base64_encode(&[2; 33]))),
            ("publicKey", json!(null)),
        ];
        for (field, value) in replacements {
            let mut changed = object.clone();
            changed[field] = value;
            assert!(PairingCode::parse(&envelope(&changed)).is_err(), "{field}");
        }
        for field in ["version", "address", "name", "publicKey", "secret"] {
            let mut missing = object.clone();
            missing.as_object_mut().unwrap().remove(field);
            assert!(
                PairingCode::parse(&envelope(&missing)).is_err(),
                "missing {field}"
            );
        }
        let mut extra = object.clone();
        extra["privateKey"] = json!("AAAA");
        assert!(
            PairingCode::parse(&envelope(&extra)).is_err(),
            "unknown fields"
        );
        let duplicate = format!(
            "{{\"version\":1,{}",
            &String::from_utf8(original.credential().unwrap().to_vec()).unwrap()[1..]
        );
        assert!(
            PairingCode::from_credential(duplicate.as_bytes()).is_err(),
            "duplicate fields"
        );
        let encoded = original.encode().unwrap();
        for malformed in [
            String::new(),
            format!("MLP2.{}", &encoded[5..]),
            "MLP1.not base64!".into(),
            encoded[5..].to_owned(),
            format!("MLP1.{}", "A".repeat(2048)),
            format!("MLP1.{}", base64_encode(&[b'A'; MAX_CODE_JSON + 1])),
        ] {
            assert!(PairingCode::parse(&malformed).is_err(), "{malformed:.20}");
        }
        assert!(
            PairingCode::new("studio.local", "", [1; 32], [2; 32]).is_err(),
            "constructor validates too"
        );
    }
}
