//! Version and security negotiation, the RSA-AES sign-in (RA2 and RA2_256)
//! as specified by the RFB community specification and implemented by neatvnc
//! (wayvnc) and TigerVNC, and, only inside Mooring's SSH tunnel to the
//! server's own loopback address, no sign-in (None, 1) or the classic VNC
//! password (VNC Authentication, 2) that x11vnc, vino and TigerVNC offer.

use crate::proto::{self, security};
use crate::stream::{EaxDirection, RfbReader, RfbWriter};
use des::Des;
use des::cipher::{BlockEncrypt, KeyInit, generic_array::GenericArray};
use rand_core::{OsRng, RngCore};
use rsa::traits::PublicKeyParts;
use rsa::{BigUint, Pkcs1v15Encrypt, RsaPrivateKey, RsaPublicKey};
use serde::Serialize;
use sha1::Sha1;
use sha2::{Digest, Sha256};
use std::fmt;
use std::io;
use std::net::IpAddr;
use zeroize::{Zeroize, Zeroizing};

pub const MIN_SERVER_KEY_BITS: u32 = 1_024;
pub const MAX_SERVER_KEY_BITS: u32 = 8_192;
pub const CLIENT_KEY_BITS: usize = 2_048;
/// RA2 limits each credential to one length byte.
pub const MAX_CREDENTIAL_BYTES: usize = 255;
/// VNC Authentication uses at most the first 8 bytes of a password; servers
/// ignore the rest.
pub const VNC_PASSWORD_BYTES: usize = 8;
/// VNC Authentication's challenge and response.
pub const VNC_CHALLENGE_BYTES: usize = 16;

/// How the viewer reaches the VNC server. Only Mooring's SSH tunnel to the
/// server's own loopback address may use a server's no-password or classic
/// VNC password sign-in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Route {
    /// Mooring's SSH tunnel to 127.0.0.0/8, ::1 or localhost on the SSH
    /// host. SSH checked the host's key, signed in with the person's own key,
    /// and encrypts every byte; the VNC port is reached only from that host.
    SshToLoopback,
    /// Anything else, such as a direct connection or an SSH tunnel whose last
    /// hop crosses a network unencrypted. Only RSA-AES is used.
    Other,
}

impl Route {
    /// The route of Mooring's SSH tunnel whose remote end is `remote_host`,
    /// as the SSH host sees it.
    pub fn ssh_tunnel_to(remote_host: &str) -> Self {
        if is_loopback_host(remote_host) {
            Self::SshToLoopback
        } else {
            Self::Other
        }
    }
}

/// Whether `host` names the SSH host itself: `localhost`, 127.0.0.0/8 or
/// ::1, with or without brackets.
pub fn is_loopback_host(host: &str) -> bool {
    let host = host
        .strip_prefix('[')
        .and_then(|h| h.strip_suffix(']'))
        .unwrap_or(host);
    host.eq_ignore_ascii_case("localhost")
        || host.parse::<IpAddr>().is_ok_and(|ip| ip.is_loopback())
}

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
    /// No VNC sign-in: the SSH key is the sign-in. Only through SSH to the
    /// server's loopback address.
    None,
    /// The classic VNC password (DES challenge and response). Only through
    /// SSH to the server's loopback address, which protects the exchange.
    VncPassword,
    RsaAes128,
    RsaAes256,
}

impl SecurityKind {
    pub fn type_id(self) -> u8 {
        match self {
            Self::None => security::NONE,
            Self::VncPassword => security::VNC_PASSWORD,
            Self::RsaAes128 => security::RA2,
            Self::RsaAes256 => security::RA2_256,
        }
    }

    /// What the person is asked for before this sign-in.
    pub fn needs(self) -> SignInNeeds {
        match self {
            Self::None => SignInNeeds::Nothing,
            Self::VncPassword => SignInNeeds::Password,
            Self::RsaAes128 | Self::RsaAes256 => SignInNeeds::Account,
        }
    }
}

/// What signing in asks of the person.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SignInNeeds {
    /// Nothing: the SSH key already signed in, and the server has no VNC
    /// password.
    Nothing,
    /// The VNC server's own password, without a username.
    Password,
    /// An account on the computer: a username and its password. RSA-AES may
    /// ask for the password alone once the handshake has run.
    Account,
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

/// Mooring's choice among the offered types: RSA-AES whenever the server
/// offers it, strongest first. Only through SSH to the server's loopback
/// address, no sign-in, then the VNC password. Apple Diffie-Hellman (30) is
/// never chosen.
pub fn choose_security(offered: &[u8], route: Route) -> Option<SecurityKind> {
    let encrypted = [SecurityKind::RsaAes256, SecurityKind::RsaAes128];
    let inside_ssh = [SecurityKind::None, SecurityKind::VncPassword];
    let allowed: &[SecurityKind] = match route {
        Route::SshToLoopback => &[encrypted[0], encrypted[1], inside_ssh[0], inside_ssh[1]],
        Route::Other => &encrypted,
    };
    allowed
        .iter()
        .copied()
        .find(|kind| offered.contains(&kind.type_id()))
}

/// Why none of `offered` can be used over `route`, for the person.
pub fn unsupported_message(offered: &[u8], route: Route) -> String {
    let names: Vec<String> = offered.iter().map(|id| id.to_string()).collect();
    let names = names.join(", ");
    let only_inside_ssh = offered
        .iter()
        .any(|id| [security::NONE, security::VNC_PASSWORD].contains(id));
    if route == Route::Other && only_inside_ssh {
        format!(
            "The VNC server offers only sign-in without encryption ({names}). Mooring uses that only through its SSH tunnel to the server’s own loopback address (127.0.0.1), so save the connection with host 127.0.0.1 as seen from the SSH host."
        )
    } else {
        format!(
            "The VNC server offers only sign-in types Mooring does not use ({names}). Mooring signs in with RSA-AES (129 or 5), or, through SSH to the server’s loopback address, with no VNC password (1) or a VNC password (2)."
        )
    }
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
pub fn negotiate(
    reader: &mut RfbReader,
    writer: &mut RfbWriter,
    route: Route,
) -> Result<Negotiated, AuthError> {
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
    let Some(security) = choose_security(&offered, route) else {
        return Err(AuthError::new(
            AuthErrorKind::UnsupportedSecurity,
            unsupported_message(&offered, route),
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
        SecurityKind::None | SecurityKind::VncPassword => unreachable!("not an RSA-AES type"),
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

/// Read VNC Authentication's random challenge.
pub fn read_vnc_challenge(reader: &mut RfbReader) -> Result<[u8; VNC_CHALLENGE_BYTES], AuthError> {
    let mut challenge = [0_u8; VNC_CHALLENGE_BYTES];
    reader.read_exact(&mut challenge)?;
    Ok(challenge)
}

/// VNC Authentication's response: the challenge encrypted with DES, keyed by
/// the password's first 8 bytes (zero-padded), each byte's bits reversed, as
/// every VNC server since the original expects. DES is weak; Mooring sends
/// this only inside SSH to the server's loopback address.
pub fn vnc_response(
    challenge: &[u8; VNC_CHALLENGE_BYTES],
    password: &[u8],
) -> Zeroizing<[u8; VNC_CHALLENGE_BYTES]> {
    let mut key = Zeroizing::new([0_u8; VNC_PASSWORD_BYTES]);
    for (slot, byte) in key.iter_mut().zip(password) {
        *slot = byte.reverse_bits();
    }
    let cipher = Des::new(GenericArray::from_slice(&key[..]));
    let mut response = Zeroizing::new(*challenge);
    for block in response.as_chunks_mut::<8>().0 {
        cipher.encrypt_block(GenericArray::from_mut_slice(block));
    }
    response
}

/// Answer VNC Authentication's challenge with the password in `credentials`.
pub fn send_vnc_response(
    writer: &mut RfbWriter,
    challenge: &[u8; VNC_CHALLENGE_BYTES],
    credentials: &Credentials,
) -> Result<(), AuthError> {
    writer.send(&vnc_response(challenge, &credentials.password)[..])?;
    Ok(())
}

/// Read SecurityResult. A rejection is `SignInRejected` with the server's
/// reason, or `fallback` when it gives none.
pub fn read_security_result(
    reader: &mut RfbReader,
    minor: u16,
    fallback: &str,
) -> Result<(), AuthError> {
    match reader.u32()? {
        0 => Ok(()),
        _ => {
            let reason = if minor >= 8 {
                read_reason(reader)
            } else {
                String::new()
            };
            let reason = if reason.is_empty() {
                fallback.to_string()
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

    const SSH: Route = Route::SshToLoopback;
    const OTHER: Route = Route::Other;

    #[test]
    fn rsa_aes_is_preferred_on_every_route_and_apple_dh_never_chosen() {
        for route in [SSH, OTHER] {
            assert_eq!(
                choose_security(&[129, 5, 30], route),
                Some(SecurityKind::RsaAes256)
            );
            assert_eq!(
                choose_security(&[30, 5], route),
                Some(SecurityKind::RsaAes128)
            );
            // RSA-AES wins even when the server also offers no password.
            assert_eq!(
                choose_security(&[1, 2, 5], route),
                Some(SecurityKind::RsaAes128)
            );
            assert_eq!(
                choose_security(&[1, 129], route),
                Some(SecurityKind::RsaAes256)
            );
            assert_eq!(choose_security(&[30], route), None);
            assert_eq!(choose_security(&[6, 19, 16, 18], route), None);
        }
    }

    #[test]
    fn no_password_and_the_vnc_password_only_through_ssh_to_loopback() {
        assert_eq!(choose_security(&[1], SSH), Some(SecurityKind::None));
        assert_eq!(choose_security(&[2], SSH), Some(SecurityKind::VncPassword));
        assert_eq!(choose_security(&[30, 2, 1], SSH), Some(SecurityKind::None));
        assert_eq!(
            choose_security(&[18, 2], SSH),
            Some(SecurityKind::VncPassword)
        );
        for offered in [&[1][..], &[2], &[30, 2, 1], &[18, 2]] {
            assert_eq!(choose_security(offered, OTHER), None, "{offered:?}");
        }
        assert!(unsupported_message(&[1], OTHER).contains("only through its SSH tunnel"));
        assert!(unsupported_message(&[30], SSH).contains("RSA-AES (129 or 5)"));
        assert_eq!(SecurityKind::None.needs(), SignInNeeds::Nothing);
        assert_eq!(SecurityKind::VncPassword.needs(), SignInNeeds::Password);
        assert_eq!(SecurityKind::RsaAes256.needs(), SignInNeeds::Account);
    }

    #[test]
    fn only_the_ssh_hosts_own_loopback_address_counts() {
        for host in [
            "127.0.0.1",
            "127.1.2.3",
            "::1",
            "[::1]",
            "localhost",
            "LOCALHOST",
        ] {
            assert!(is_loopback_host(host), "{host}");
            assert_eq!(Route::ssh_tunnel_to(host), SSH, "{host}");
        }
        for host in [
            "",
            "0.0.0.0",
            "::",
            "192.168.1.20",
            "10.0.0.1",
            "localhost.example.com",
            "127.0.0.1.example.com",
            "thinknvidia.local",
            "::ffff:192.168.1.1",
            "[::1",
        ] {
            assert!(!is_loopback_host(host), "{host}");
            assert_eq!(Route::ssh_tunnel_to(host), OTHER, "{host}");
        }
    }

    #[test]
    fn the_vnc_response_matches_known_answers() {
        // OpenSSL's DES-ECB with the bit-reversed key and libvncserver's
        // rfbEncryptBytes (x11vnc 0.9.13 on Ubuntu 18.04) both give these.
        const KNOWN_PASSWORD: &str = "5645abeb5f1e6475e8feb11beb66ea19";
        const KNOWN_EMPTY: &str = "a068dbeab73d140b56541eb3c7625177";
        let challenge: [u8; 16] = *b"0123456789abcdef";
        assert_eq!(
            hex(&vnc_response(&challenge, b"password")[..]),
            KNOWN_PASSWORD
        );
        // Only the first 8 bytes count, and shorter ones are zero-padded.
        assert_eq!(
            vnc_response(&challenge, b"password-longer")[..],
            vnc_response(&challenge, b"password")[..]
        );
        assert_eq!(hex(&vnc_response(&challenge, b"")[..]), KNOWN_EMPTY);
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
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
