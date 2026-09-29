//! Out-of-band pairing codes and saved peer credentials.
//!
//! A code is `MLP1.` + standard padded base64 of a JSON object with exactly
//! `version` (1), `address`, `name`, `publicKey` and `secret` (both base64 of
//! 32 bytes). Keychain credentials hold the same JSON without the envelope, so
//! pairings saved by earlier builds remain readable. The secret is the long-lived
//! pairing PSK: intermediate copies are zeroized and Debug output omits it.

use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};

pub(crate) const MAX_NAME_BYTES: usize = 160;
const PREFIX: &str = "MLP1.";
const MAX_CODE_TEXT: usize = 2048;
const MAX_CODE_JSON: usize = 1024;
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

fn base64_encode(bytes: &[u8]) -> String {
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
fn base64_decode(text: &str) -> Option<Vec<u8>> {
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
    secret: String,
}
impl Drop for Wire {
    fn drop(&mut self) {
        self.secret.zeroize();
    }
}

#[derive(Clone, PartialEq, Eq)]
pub(crate) struct PairingCode {
    pub address: String,
    pub name: String,
    pub public_key: [u8; 32],
    pub secret: [u8; 32],
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
            .field("name", &self.name)
            .field("peer_id", &self.peer_id())
            .finish_non_exhaustive()
    }
}

impl PairingCode {
    /// Strict: every received or saved code must already satisfy these rules.
    pub(crate) fn new(
        address: &str,
        name: &str,
        public_key: [u8; 32],
        secret: [u8; 32],
    ) -> Result<Self> {
        validate_name(name)?;
        Ok(Self {
            address: normalize_address(address)?,
            name: name.to_owned(),
            public_key,
            secret,
        })
    }

    /// For the sharing Mac's own code: the computer name is normalized.
    pub(crate) fn for_host(
        address: &str,
        computer_name: &str,
        public_key: [u8; 32],
        secret: [u8; 32],
    ) -> Result<Self> {
        Self::new(address, &local_name(computer_name), public_key, secret)
    }

    /// Lowercase hex SHA-256 of the public key: no secret, name or address.
    pub(crate) fn peer_id(&self) -> String {
        Sha256::digest(self.public_key)
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }

    /// The JSON stored in Keychain; also the payload inside a pairing code.
    pub(crate) fn credential(&self) -> Zeroizing<Vec<u8>> {
        let wire = Wire {
            version: 1,
            address: self.address.clone(),
            name: self.name.clone(),
            public_key: base64_encode(&self.public_key),
            secret: base64_encode(&self.secret),
        };
        Zeroizing::new(
            serde_json::to_vec(&wire).expect("pairing JSON has only string and integer fields"),
        )
    }

    pub(crate) fn from_credential(bytes: &[u8]) -> Result<Self> {
        if bytes.len() > MAX_CODE_JSON {
            return Err(Error::Invalid);
        }
        let wire: Wire = serde_json::from_slice(bytes).map_err(|_| Error::Invalid)?;
        if wire.version != 1 {
            return Err(Error::Invalid);
        }
        Self::new(
            &wire.address,
            &wire.name,
            key(&wire.public_key)?,
            key(&wire.secret)?,
        )
    }

    pub(crate) fn encode(&self) -> Zeroizing<String> {
        let payload = Zeroizing::new(base64_encode(&self.credential()));
        Zeroizing::new(PREFIX.to_owned() + &payload)
    }

    pub(crate) fn parse(text: &str) -> Result<Self> {
        let text = text.trim();
        if text.len() > MAX_CODE_TEXT {
            return Err(Error::Invalid);
        }
        let payload = text.strip_prefix(PREFIX).ok_or(Error::Invalid)?;
        let json = Zeroizing::new(base64_decode(payload).ok_or(Error::Invalid)?);
        Self::from_credential(&json)
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
        let parsed =
            PairingCode::parse(&format!(" \n\t{}\r\n ", original.encode().as_str())).unwrap();
        assert_eq!(parsed, original);
        assert_eq!(
            PairingCode::from_credential(&original.credential()).unwrap(),
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
        assert_eq!(PairingCode::parse(&long.encode()).unwrap().name, maximum);
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
        assert!(PairingCode::for_host("studio.local", "A\u{200d}B", [1; 32], [2; 32]).is_ok());
    }

    #[test]
    fn parser_rejects_every_invalid_field_and_envelope() {
        let original = code();
        let object: Value = serde_json::from_slice(&original.credential()).unwrap();
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
            &String::from_utf8(original.credential().to_vec()).unwrap()[1..]
        );
        assert!(
            PairingCode::from_credential(duplicate.as_bytes()).is_err(),
            "duplicate fields"
        );
        let encoded = original.encode();
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
