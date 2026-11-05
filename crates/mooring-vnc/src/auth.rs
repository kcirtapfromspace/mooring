//! Version and security negotiation, and the RSA-AES sign-in (RA2 and
//! RA2_256) as specified by the RFB community specification and implemented
//! by neatvnc (wayvnc) and TigerVNC.

use crate::proto::{self, security};
use crate::stream::{EaxDirection, RfbReader, RfbWriter};
use rand_core::{OsRng, RngCore};
use rsa::traits::PublicKeyParts;
use rsa::{BigUint, Pkcs1v15Encrypt, RsaPrivateKey, RsaPublicKey};
use serde::Serialize;
use sha1::Sha1;
use sha2::{Digest, Sha256};
use std::fmt;
use std::io;
use zeroize::{Zeroize, Zeroizing};

pub const MIN_SERVER_KEY_BITS: u32 = 1_024;
pub const MAX_SERVER_KEY_BITS: u32 = 8_192;
pub const CLIENT_KEY_BITS: usize = 2_048;
/// RA2 limits each credential to one length byte.
pub const MAX_CREDENTIAL_BYTES: usize = 255;

/// A username and password for one sign-in attempt. The password is wiped
/// when this is dropped, and neither is ever printed.
pub struct Credentials {
    username: String,
    password: Zeroizing<Vec<u8>>,
}

impl Credentials {
    pub fn new(username: &str, password: Vec<u8>) -> Result<Self, String> {
        let password = Zeroizing::new(password);
        if username.len() > MAX_CREDENTIAL_BYTES || password.len() > MAX_CREDENTIAL_BYTES {
            return Err(format!(
                "The username and password must each be at most {MAX_CREDENTIAL_BYTES} bytes."
            ));
        }
        if username.chars().any(char::is_control) {
            return Err("The username can’t contain control characters.".into());
        }
        Ok(Self {
            username: username.to_owned(),
            password,
        })
    }

    pub fn username(&self) -> &str {
        &self.username
    }
}

impl fmt::Debug for Credentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Credentials")
            .field("username", &self.username)
            .field("password", &"<hidden>")
            .finish()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SecurityKind {
    None,
    RsaAes128,
    RsaAes256,
}

impl SecurityKind {
    pub fn type_id(self) -> u8 {
        match self {
            Self::None => security::NONE,
            Self::RsaAes128 => security::RA2,
            Self::RsaAes256 => security::RA2_256,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthErrorKind {
    NotVnc,
    UnsupportedVersion,
    /// The server refused before sign-in, with a reason.
    ServerRefused,
    /// No offered security type is one Mooring will use.
    UnsupportedSecurity,
    /// The server's key or handshake was invalid or did not verify.
    HandshakeFailed,
    /// The server rejected the username or password.
    SignInRejected,
    CredentialsNeeded,
    Io,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct AuthError {
    pub kind: AuthErrorKind,
    pub message: String,
}

impl AuthError {
    fn new(kind: AuthErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

impl From<io::Error> for AuthError {
    fn from(error: io::Error) -> Self {
        let message = match error.kind() {
            io::ErrorKind::UnexpectedEof => {
                "The server closed the connection during sign-in.".to_string()
            }
            _ => format!("The connection failed during sign-in: {error}"),
        };
        Self::new(AuthErrorKind::Io, message)
    }
}

impl fmt::Display for AuthError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

/// Mooring's choice among the offered types, strongest first. Apple
/// Diffie-Hellman (30) and the plain VNC password (2) are never chosen.
pub fn choose_security(offered: &[u8]) -> Option<SecurityKind> {
    [
        SecurityKind::RsaAes256,
        SecurityKind::RsaAes128,
        SecurityKind::None,
    ]
    .into_iter()
    .find(|kind| offered.contains(&kind.type_id()))
}

/// What the server's greeting and security list said.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Negotiated {
    pub rfb_version: String,
    pub offered: Vec<u8>,
    pub security: SecurityKind,
    /// Minor version Mooring replied with: 7 or 8.
    #[serde(skip)]
    pub minor: u16,
}

fn read_reason(reader: &mut RfbReader) -> String {
    reader
        .u32()
        .and_then(|length| reader.bytes(length, proto::MAX_REASON_BYTES))
        .map(|bytes| {
            String::from_utf8_lossy(&bytes)
                .chars()
                .filter(|c| !c.is_control())
                .take(300)
                .collect()
        })
        .unwrap_or_default()
}

/// Exchange versions and choose a security type.
pub fn negotiate(reader: &mut RfbReader, writer: &mut RfbWriter) -> Result<Negotiated, AuthError> {
    let mut greeting = [0_u8; 12];
    reader.read_exact(&mut greeting)?;
    let Some((major, minor)) = proto::parse_version(&greeting) else {
        return Err(AuthError::new(
            AuthErrorKind::NotVnc,
            "The server did not answer with a VNC greeting.",
        ));
    };
    let rfb_version = String::from_utf8_lossy(&greeting[4..11]).into_owned();
    if major != 3 || minor < 7 {
        return Err(AuthError::new(
            AuthErrorKind::UnsupportedVersion,
            format!("The server speaks RFB {rfb_version}; Mooring needs 3.7 or later."),
        ));
    }
    if minor == 889 {
        return Err(AuthError::new(
            AuthErrorKind::UnsupportedVersion,
            "This is a Mac. Pair it with Mooring for a native connection instead.",
        ));
    }
    let minor = minor.min(8);
    writer.send(format!("RFB 003.00{minor}\n").as_bytes())?;
    let count = reader.u8()?;
    if count == 0 {
        let reason = read_reason(reader);
        return Err(AuthError::new(
            AuthErrorKind::ServerRefused,
            format!("The VNC server refused the connection: {reason}"),
        ));
    }
    let mut offered = vec![0_u8; usize::from(count)];
    reader.read_exact(&mut offered)?;
    let Some(security) = choose_security(&offered) else {
        let names: Vec<String> = offered.iter().map(|id| id.to_string()).collect();
        return Err(AuthError::new(
            AuthErrorKind::UnsupportedSecurity,
            format!(
                "The VNC server offers only sign-in types Mooring does not use ({}). Mooring signs in with RSA-AES (129 or 5).",
                names.join(", ")
            ),
        ));
    };
    writer.send(&[security.type_id()])?;
    Ok(Negotiated {
        rfb_version,
        offered,
        security,
        minor,
    })
}

/// A public key as RSA-AES sends it: bit length, then modulus and exponent,
/// each padded to the key's byte length.
pub(crate) fn key_message(key: &RsaPublicKey) -> Vec<u8> {
    let length = key.size();
    let mut out = Vec::with_capacity(4 + length * 2);
    out.extend_from_slice(&((length * 8) as u32).to_be_bytes());
    for part in [key.n(), key.e()] {
        let bytes = part.to_bytes_be();
        out.resize(out.len() + length - bytes.len(), 0);
        out.extend_from_slice(&bytes);
    }
    out
}

pub(crate) fn hash(kind: SecurityKind, parts: &[&[u8]]) -> Zeroizing<Vec<u8>> {
    let digest = match kind {
        SecurityKind::RsaAes256 => {
            let mut hasher = Sha256::new();
            parts.iter().for_each(|part| hasher.update(part));
            hasher.finalize().to_vec()
        }
        _ => {
            let mut hasher = Sha1::new();
            parts.iter().for_each(|part| hasher.update(part));
            hasher.finalize().to_vec()
        }
    };
    Zeroizing::new(digest)
}

/// What the RSA-AES handshake established before credentials.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Ra2Session {
    pub server_key_bits: u32,
    /// SHA-256 of the server's key message, for display.
    pub server_key_sha256: String,
    /// 1: username and password; 2: password only.
    pub credential_subtype: u8,
}

/// Generate the client's RSA key. This takes a moment, so callers start it
/// while the network connection is still being set up.
pub fn client_key() -> Result<RsaPrivateKey, AuthError> {
    RsaPrivateKey::new(&mut OsRng, CLIENT_KEY_BITS).map_err(|error| {
        AuthError::new(
            AuthErrorKind::HandshakeFailed,
            format!("Could not create a key: {error}"),
        )
    })
}

/// Run RSA-AES up to the server's credential request. Both halves of the
/// stream are encrypted when this returns.
pub fn ra2_handshake(
    kind: SecurityKind,
    reader: &mut RfbReader,
    writer: &mut RfbWriter,
    client_key: &RsaPrivateKey,
) -> Result<Ra2Session, AuthError> {
    let (random_len, key_len) = match kind {
        SecurityKind::RsaAes256 => (32, 32),
        SecurityKind::RsaAes128 => (16, 16),
        SecurityKind::None => unreachable!("not an RSA-AES type"),
    };
    let invalid = |message: &str| AuthError::new(AuthErrorKind::HandshakeFailed, message);
    let server_bits = reader.u32()?;
    if !(MIN_SERVER_KEY_BITS..=MAX_SERVER_KEY_BITS).contains(&server_bits) {
        return Err(invalid(&format!(
            "The server’s RSA key is {server_bits} bits; Mooring accepts 1024 to 8192."
        )));
    }
    let server_len = server_bits.div_ceil(8) as usize;
    let mut server_message = Vec::with_capacity(4 + server_len * 2);
    server_message.extend_from_slice(&server_bits.to_be_bytes());
    server_message.resize(4 + server_len * 2, 0);
    reader.read_exact(&mut server_message[4..])?;
    let server_key = RsaPublicKey::new_with_max_size(
        BigUint::from_bytes_be(&server_message[4..4 + server_len]),
        BigUint::from_bytes_be(&server_message[4 + server_len..]),
        MAX_SERVER_KEY_BITS as usize,
    )
    .map_err(|_| invalid("The server sent an RSA key that is not valid."))?;

    let client_public = RsaPublicKey::from(client_key);
    let client_message = key_message(&client_public);
    writer.send(&client_message)?;

    // The server's random number, encrypted to our key.
    let length = reader.u16()?;
    if usize::from(length) != client_public.size() {
        return Err(invalid(
            "The server’s encrypted random number has the wrong length.",
        ));
    }
    let encrypted = reader.bytes(u32::from(length), 1024)?;
    let server_random = Zeroizing::new(
        client_key
            .decrypt(Pkcs1v15Encrypt, &encrypted)
            .map_err(|_| invalid("Could not decrypt the server’s random number."))?,
    );
    if server_random.len() != random_len {
        return Err(invalid("The server’s random number has the wrong length."));
    }
    let mut client_random = Zeroizing::new(vec![0_u8; random_len]);
    OsRng.fill_bytes(&mut client_random);
    let encrypted = server_key
        .encrypt(&mut OsRng, Pkcs1v15Encrypt, &client_random)
        .map_err(|_| invalid("Could not encrypt to the server’s key."))?;
    let mut message = (encrypted.len() as u16).to_be_bytes().to_vec();
    message.extend_from_slice(&encrypted);
    writer.send(&message)?;

    let client_session = hash(kind, &[&server_random, &client_random]);
    let server_session = hash(kind, &[&client_random, &server_random]);
    writer
        .encrypt_from_now(EaxDirection::new(&client_session[..key_len]).map_err(|e| invalid(&e))?);
    reader
        .encrypt_from_now(EaxDirection::new(&server_session[..key_len]).map_err(|e| invalid(&e))?);

    let expected_server_hash = hash(kind, &[&server_message, &client_message]);
    let mut server_hash = Zeroizing::new(vec![0_u8; expected_server_hash.len()]);
    reader.read_exact(&mut server_hash)?;
    if *server_hash != *expected_server_hash {
        return Err(invalid(
            "The server’s handshake hash did not match. The connection may have been tampered with.",
        ));
    }
    writer.send(&hash(kind, &[&client_message, &server_message]))?;
    let credential_subtype = reader.u8()?;
    if !matches!(credential_subtype, 1 | 2) {
        return Err(invalid(
            "The server asked for an unknown kind of credentials.",
        ));
    }
    let fingerprint = Sha256::digest(&server_message);
    Ok(Ra2Session {
        server_key_bits: server_bits,
        server_key_sha256: fingerprint.iter().map(|b| format!("{b:02x}")).collect(),
        credential_subtype,
    })
}

/// Send the credentials for an RSA-AES subtype, over the encrypted stream.
pub fn send_credentials(
    writer: &mut RfbWriter,
    subtype: u8,
    credentials: &Credentials,
) -> Result<(), AuthError> {
    let username = if subtype == 1 {
        credentials.username.as_bytes()
    } else {
        &[]
    };
    let mut message = Zeroizing::new(Vec::with_capacity(
        2 + username.len() + credentials.password.len(),
    ));
    message.push(username.len() as u8);
    message.extend_from_slice(username);
    message.push(credentials.password.len() as u8);
    message.extend_from_slice(&credentials.password);
    writer.send(&message)?;
    Ok(())
}

/// Read SecurityResult. A rejection is `SignInRejected` with the server's reason.
pub fn read_security_result(reader: &mut RfbReader, minor: u16) -> Result<(), AuthError> {
    match reader.u32()? {
        0 => Ok(()),
        _ => {
            let reason = if minor >= 8 {
                read_reason(reader)
            } else {
                String::new()
            };
            let reason = if reason.is_empty() {
                "the username or password was not accepted".to_string()
            } else {
                reason
            };
            Err(AuthError::new(
                AuthErrorKind::SignInRejected,
                format!("The VNC server did not accept the sign-in: {reason}."),
            ))
        }
    }
}

/// Wipe a password buffer that came from outside, such as the app.
pub fn wipe(bytes: &mut [u8]) {
    bytes.zeroize();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mooring_prefers_rsa_aes_and_never_picks_apple_dh_or_des() {
        assert_eq!(
            choose_security(&[129, 5, 30]),
            Some(SecurityKind::RsaAes256)
        );
        assert_eq!(choose_security(&[30, 5]), Some(SecurityKind::RsaAes128));
        assert_eq!(choose_security(&[30, 2, 1]), Some(SecurityKind::None));
        assert_eq!(choose_security(&[30]), None);
        assert_eq!(choose_security(&[2]), None);
        assert_eq!(choose_security(&[6, 19, 16]), None);
    }

    #[test]
    fn credentials_are_bounded_and_never_printed() {
        let credentials = Credentials::new("alex", b"hunter2".to_vec()).unwrap();
        let printed = format!("{credentials:?}");
        assert!(printed.contains("alex") && !printed.contains("hunter2"));
        assert!(Credentials::new("alex", vec![b'x'; 256]).is_err());
        assert!(Credentials::new(&"u".repeat(256), Vec::new()).is_err());
        assert!(Credentials::new("bad\nname", Vec::new()).is_err());
    }

    #[test]
    fn key_messages_pad_the_exponent_to_the_key_length() {
        let key = RsaPrivateKey::new(&mut OsRng, 1024).unwrap();
        let message = key_message(&RsaPublicKey::from(&key));
        assert_eq!(message.len(), 4 + 128 * 2);
        assert_eq!(&message[..4], &1024_u32.to_be_bytes());
        // 65537 = 0x010001, right-aligned in 128 bytes.
        assert_eq!(&message[4 + 128..4 + 128 + 125], &[0_u8; 125][..]);
        assert_eq!(&message[4 + 256 - 3..], &[1, 0, 1]);
    }
}
