//! Pairing PINs: six characters a person reads on the sharing Mac and types on
//! the viewer, in place of copying a long code between them.
//!
//! A PIN carries about 30 bits, far too few to use as a key: anyone who saw one
//! attempt could try every PIN offline. SPAKE2 (RustCrypto's `spake2`, MIT OR
//! Apache-2.0) turns it into a full-strength key that each side gets only if
//! both used the same PIN, so each guess costs a live attempt, and the sharing
//! Mac allows only a few. The sharing Mac's public key is bound into the
//! exchange, and the key then serves as the pairing secret of the usual
//! per-device handshake (see `transport`).
//!
//! The sharing Mac makes one PIN at a time. It works once, within
//! `PAIRING_LIFETIME`, and stops after `MAX_TRIES` attempts that didn't finish.

use crate::pairing::{CodeKind, PairingCode, fitted_alternates, local_name, normalize_address};
use crate::{Error, Result};
use curve25519_dalek::edwards::CompressedEdwardsY;
use serde::{Deserialize, Serialize};
use spake2::{Ed25519Group, Identity, Password, Spake2};
use zeroize::Zeroizing;

pub(crate) const PIN_LENGTH: usize = 6;
/// Crockford's base32: no I, L, O or U, so no character reads as another.
const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
/// Attempts one PIN allows; each counts as it starts.
pub(crate) const MAX_TRIES: u8 = 5;
/// What a person may type: the PIN with spaces or dashes between.
const MAX_TYPED: usize = 32;
/// A SPAKE2 message: the side, then an Edwards point.
pub(crate) const MESSAGE_LENGTH: usize = 33;
const VIEWER_IDENTITY: &[u8] = b"mooring-pin/1 viewer";
const HOST_IDENTITY: &[u8] = b"mooring-pin/1 host ";

pub(crate) type Pin = Zeroizing<[u8; PIN_LENGTH]>;

/// A new random PIN. 32 divides 256, so each character is uniform.
pub(crate) fn generate() -> Result<Pin> {
    let mut random = Zeroizing::new([0_u8; PIN_LENGTH]);
    getrandom::fill(&mut *random).map_err(|_| Error::Internal)?;
    let mut pin = Zeroizing::new([0_u8; PIN_LENGTH]);
    for (slot, byte) in pin.iter_mut().zip(random.iter()) {
        *slot = ALPHABET[usize::from(byte & 31)];
    }
    Ok(pin)
}

/// The PIN a person typed. Case, spaces and dashes don't matter, and O, I and
/// L read as 0, 1 and 1.
pub(crate) fn normalize(text: &str) -> Result<Pin> {
    if text.len() > MAX_TYPED {
        return Err(Error::Invalid);
    }
    let mut pin = Zeroizing::new([0_u8; PIN_LENGTH]);
    let mut count = 0;
    for character in text
        .chars()
        .filter(|character| !matches!(character, ' ' | '-'))
    {
        let character = match character.to_ascii_uppercase() {
            'O' => '0',
            'I' | 'L' => '1',
            other => other,
        };
        let byte = u8::try_from(character)
            .ok()
            .filter(|byte| ALPHABET.contains(byte))
            .ok_or(Error::Invalid)?;
        *pin.get_mut(count).ok_or(Error::Invalid)? = byte;
        count += 1;
    }
    if count != PIN_LENGTH {
        return Err(Error::Invalid);
    }
    Ok(pin)
}

/// One side of the exchange, waiting for the other's message.
pub(crate) struct Exchange(Spake2<Ed25519Group>);

/// Starts the exchange for `pin` with the sharing Mac whose key is
/// `host_public`, as the host or the viewer. Returns the message to send.
pub(crate) fn start(
    pin: &Pin,
    host_public: &[u8; 32],
    host: bool,
) -> (Exchange, [u8; MESSAGE_LENGTH]) {
    let password = Password::new(**pin);
    let viewer = Identity::new(VIEWER_IDENTITY);
    let sharing = Identity::new(&[HOST_IDENTITY, host_public].concat());
    let (state, message) = if host {
        Spake2::<Ed25519Group>::start_b(&password, &viewer, &sharing)
    } else {
        Spake2::<Ed25519Group>::start_a(&password, &viewer, &sharing)
    };
    let mut fixed = [0_u8; MESSAGE_LENGTH];
    fixed.copy_from_slice(&message);
    (Exchange(state), fixed)
}

/// The shared key from the other side's message. Each side gets the same key
/// only if both used the same PIN; a wrong one shows as a failed handshake.
pub(crate) fn finish(exchange: Exchange, message: &[u8]) -> Result<Zeroizing<[u8; 32]>> {
    // A small-order point would let the other side choose the result; it is
    // never an honest message.
    let point: [u8; 32] = message
        .get(1..)
        .and_then(|bytes| bytes.try_into().ok())
        .ok_or(Error::Protocol)?;
    if message.len() != MESSAGE_LENGTH
        || CompressedEdwardsY(point)
            .decompress()
            .is_none_or(|point| point.is_small_order())
    {
        return Err(Error::Protocol);
    }
    let key = Zeroizing::new(exchange.0.finish(message).map_err(|_| Error::Protocol)?);
    let mut fixed = Zeroizing::new([0_u8; 32]);
    fixed.copy_from_slice(key.get(..32).ok_or(Error::Internal)?);
    Ok(fixed)
}

/// What the sharing Mac tells a viewer that paired with its PIN: the name and
/// addresses a one-time code would carry. Its public key comes from the
/// exchange itself.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct HostInfo {
    pub name: String,
    pub address: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub addresses: Vec<String>,
}
impl HostInfo {
    /// The sharing Mac's own details: its name made valid, and of its other
    /// addresses those that qualify and fit.
    pub(crate) fn for_host(
        address: &str,
        computer_name: &str,
        alternates: &[String],
    ) -> Result<Self> {
        let address = normalize_address(address)?;
        Ok(Self {
            name: local_name(computer_name),
            addresses: fitted_alternates(&address, alternates),
            address,
        })
    }
    pub(crate) fn encode(&self) -> Result<Vec<u8>> {
        serde_json::to_vec(self).map_err(|_| Error::Internal)
    }
    /// The viewer's saved pairing for this sharing Mac, checked strictly.
    pub(crate) fn pairing(bytes: &[u8], host_public: &[u8; 32]) -> Result<PairingCode> {
        let info: Self = serde_json::from_slice(bytes).map_err(|_| Error::Protocol)?;
        PairingCode::of_kind(
            &info.address,
            &info.name,
            *host_public,
            [0; 32],
            CodeKind::Device,
        )
        .and_then(|code| code.with_alternates(&info.addresses))
        .map_err(|_| Error::Protocol)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pins_are_six_unambiguous_characters_and_typing_is_forgiving() {
        for _ in 0..200 {
            let pin = generate().unwrap();
            assert!(pin.iter().all(|byte| ALPHABET.contains(byte)));
            assert_eq!(
                *normalize(std::str::from_utf8(&*pin).unwrap()).unwrap(),
                *pin
            );
        }
        assert_eq!(&*normalize("k7q m2p").unwrap(), b"K7QM2P");
        assert_eq!(&*normalize("K7Q-M2P").unwrap(), b"K7QM2P");
        assert_eq!(
            &*normalize("oil 9zz").unwrap(),
            b"0119ZZ",
            "O, I and L read as digits"
        );
        for invalid in [
            "",
            "K7QM2",
            "K7QM2PX",
            "K7QU2P",
            "K7Q.M2P",
            "K7QM2\u{0}",
            "Ｋ7QM2P",
            " ".repeat(40).as_str(),
        ] {
            assert_eq!(
                normalize(invalid).map(|_| ()),
                Err(Error::Invalid),
                "{invalid:?}"
            );
        }
    }

    #[test]
    fn the_same_pin_and_host_key_give_both_sides_one_key() {
        let host_key = [7_u8; 32];
        let pin = normalize("K7QM2P").unwrap();
        let (host, host_message) = start(&pin, &host_key, true);
        let (viewer, viewer_message) = start(&pin, &host_key, false);
        let host_secret = finish(host, &viewer_message).unwrap();
        assert_eq!(*host_secret, *finish(viewer, &host_message).unwrap());

        // Another PIN, or another sharing Mac's key, gives another key.
        for (typed, key) in [("K7QM2Q", host_key), ("K7QM2P", [8; 32])] {
            let (host, host_message) = start(&pin, &host_key, true);
            let (viewer, viewer_message) = start(&normalize(typed).unwrap(), &key, false);
            let host_secret = finish(host, &viewer_message).unwrap();
            assert_ne!(*host_secret, *finish(viewer, &host_message).unwrap());
        }

        // Malformed messages, and a message from the same side, are refused.
        let identity_point = {
            let mut message = [0_u8; MESSAGE_LENGTH];
            message[0] = b'A';
            message[1] = 1;
            message
        };
        for message in [
            &identity_point[..],
            &viewer_message[..32],
            &[0; MESSAGE_LENGTH][..],
        ] {
            let (host, _) = start(&pin, &host_key, true);
            assert_eq!(finish(host, message).map(|_| ()), Err(Error::Protocol));
        }
        let (viewer, _) = start(&pin, &host_key, false);
        let (_, other_viewer) = start(&pin, &host_key, false);
        assert_eq!(
            finish(viewer, &other_viewer).map(|_| ()),
            Err(Error::Protocol)
        );
    }

    #[test]
    fn host_details_round_trip_and_are_checked_strictly() {
        let info = HostInfo::for_host(
            "Studio.local",
            " Studio\u{200b} ",
            &[
                "192.168.1.5".into(),
                "studio.local".into(),
                "http://bad".into(),
            ],
        )
        .unwrap();
        assert_eq!(
            info,
            HostInfo {
                name: "Studio".into(),
                address: "studio.local".into(),
                addresses: vec!["192.168.1.5".into()]
            }
        );
        let code = HostInfo::pairing(&info.encode().unwrap(), &[9; 32]).unwrap();
        assert_eq!(
            (
                code.address.as_str(),
                code.alternates.clone(),
                code.name.as_str(),
                code.public_key,
                code.kind
            ),
            (
                "studio.local",
                vec!["192.168.1.5".to_string()],
                "Studio",
                [9; 32],
                CodeKind::Device
            )
        );
        for bad in [
            &br#"{"name":"Studio","address":"vnc://studio.local"}"#[..],
            br#"{"name":"","address":"studio.local"}"#,
            br#"{"name":"Studio","address":"studio.local","addresses":["studio.local"]}"#,
            br#"{"name":"Studio","address":"studio.local","secret":"x"}"#,
            b"not json",
        ] {
            assert_eq!(
                HostInfo::pairing(bad, &[9; 32]).map(|_| ()),
                Err(Error::Protocol)
            );
        }
    }
}
