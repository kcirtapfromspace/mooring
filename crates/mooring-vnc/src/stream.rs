//! The byte stream under RFB, plain or wrapped in RSA-AES's AES-EAX layer.
//!
//! After an RSA-AES handshake every byte in each direction travels in
//! messages of a 2-byte big-endian length (also the associated data), the
//! ciphertext, and a 16-byte tag. Each direction has its own key, and the
//! nonce is a 128-bit little-endian message counter starting at zero. A
//! message that fails authentication ends the session.

use aes::{Aes128, Aes256};
use eax::Eax;
use eax::aead::generic_array::GenericArray;
use eax::aead::{AeadInPlace, KeyInit};
use std::io::{self, BufReader, Read, Write};
use zeroize::Zeroize;

/// Mooring's encrypted messages stay well under neatvnc's 8 KiB read buffer.
pub const MAX_SEND_CHUNK: usize = 4_096;
const TAG_BYTES: usize = 16;

enum Cipher {
    Aes128(Box<Eax<Aes128>>),
    Aes256(Box<Eax<Aes256>>),
}

/// One direction of the AES-EAX layer.
pub struct EaxDirection {
    cipher: Cipher,
    counter: u128,
}

impl EaxDirection {
    /// `key` is 16 bytes (AES-128) or 32 bytes (AES-256).
    pub fn new(key: &[u8]) -> Result<Self, String> {
        let cipher = match key.len() {
            16 => Cipher::Aes128(Box::new(Eax::new(GenericArray::from_slice(key)))),
            32 => Cipher::Aes256(Box::new(Eax::new(GenericArray::from_slice(key)))),
            other => return Err(format!("AES-EAX key of {other} bytes")),
        };
        Ok(Self { cipher, counter: 0 })
    }

    fn next_nonce(&mut self) -> [u8; 16] {
        let nonce = self.counter.to_le_bytes();
        self.counter = self.counter.wrapping_add(1);
        nonce
    }

    pub fn seal(&mut self, aad: &[u8], data: &mut [u8]) -> [u8; TAG_BYTES] {
        let nonce = self.next_nonce();
        let nonce = GenericArray::from_slice(&nonce);
        let tag = match &self.cipher {
            Cipher::Aes128(cipher) => cipher.encrypt_in_place_detached(nonce, aad, data),
            Cipher::Aes256(cipher) => cipher.encrypt_in_place_detached(nonce, aad, data),
        }
        .expect("EAX encryption cannot fail for in-memory data");
        tag.into()
    }

    pub fn open(&mut self, aad: &[u8], data: &mut [u8], tag: &[u8; TAG_BYTES]) -> bool {
        let nonce = self.next_nonce();
        let nonce = GenericArray::from_slice(&nonce);
        let tag = GenericArray::from_slice(tag);
        match &self.cipher {
            Cipher::Aes128(cipher) => cipher.decrypt_in_place_detached(nonce, aad, data, tag),
            Cipher::Aes256(cipher) => cipher.decrypt_in_place_detached(nonce, aad, data, tag),
        }
        .is_ok()
    }
}

/// The server-to-client half.
pub struct RfbReader {
    inner: BufReader<Box<dyn Read + Send>>,
    decrypt: Option<EaxDirection>,
    plain: Vec<u8>,
    position: usize,
    wire_bytes: u64,
}

impl RfbReader {
    pub fn new(inner: Box<dyn Read + Send>) -> Self {
        Self {
            inner: BufReader::with_capacity(64 * 1024, inner),
            decrypt: None,
            plain: Vec::new(),
            position: 0,
            wire_bytes: 0,
        }
    }

    /// Bytes taken from the network so far, encryption overhead included.
    pub fn wire_bytes(&self) -> u64 {
        self.wire_bytes
    }

    /// Every byte after this call is read through the AES-EAX layer.
    pub fn encrypt_from_now(&mut self, direction: EaxDirection) {
        self.decrypt = Some(direction);
    }

    fn next_message(&mut self) -> io::Result<()> {
        let Some(direction) = self.decrypt.as_mut() else {
            unreachable!("only called when encrypted");
        };
        let mut header = [0_u8; 2];
        self.inner.read_exact(&mut header)?;
        let length = usize::from(u16::from_be_bytes(header));
        self.plain.zeroize();
        self.plain.clear();
        self.plain.resize(length, 0);
        self.inner.read_exact(&mut self.plain)?;
        let mut tag = [0_u8; TAG_BYTES];
        self.inner.read_exact(&mut tag)?;
        self.wire_bytes += (2 + length + TAG_BYTES) as u64;
        if !direction.open(&header, &mut self.plain, &tag) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "an encrypted message from the server failed authentication",
            ));
        }
        self.position = 0;
        Ok(())
    }

    pub fn read_exact(&mut self, out: &mut [u8]) -> io::Result<()> {
        if self.decrypt.is_none() {
            self.inner.read_exact(out)?;
            self.wire_bytes += out.len() as u64;
            return Ok(());
        }
        let mut filled = 0;
        while filled < out.len() {
            if self.position == self.plain.len() {
                self.next_message()?;
                continue;
            }
            let take = (self.plain.len() - self.position).min(out.len() - filled);
            out[filled..filled + take]
                .copy_from_slice(&self.plain[self.position..self.position + take]);
            self.position += take;
            filled += take;
        }
        Ok(())
    }

    pub fn u8(&mut self) -> io::Result<u8> {
        let mut byte = [0_u8; 1];
        self.read_exact(&mut byte)?;
        Ok(byte[0])
    }

    pub fn u16(&mut self) -> io::Result<u16> {
        let mut bytes = [0_u8; 2];
        self.read_exact(&mut bytes)?;
        Ok(u16::from_be_bytes(bytes))
    }

    pub fn u32(&mut self) -> io::Result<u32> {
        let mut bytes = [0_u8; 4];
        self.read_exact(&mut bytes)?;
        Ok(u32::from_be_bytes(bytes))
    }

    pub fn i32(&mut self) -> io::Result<i32> {
        Ok(self.u32()? as i32)
    }

    /// Read exactly `length` bytes, refusing more than `limit`.
    pub fn bytes(&mut self, length: u32, limit: u32) -> io::Result<Vec<u8>> {
        if length > limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("the server sent {length} bytes where at most {limit} are allowed"),
            ));
        }
        let mut out = vec![0_u8; length as usize];
        self.read_exact(&mut out)?;
        Ok(out)
    }

    /// Discard `length` bytes without holding them.
    pub fn skip(&mut self, mut length: u64) -> io::Result<()> {
        let mut scratch = [0_u8; 4096];
        while length > 0 {
            let take = length.min(scratch.len() as u64) as usize;
            self.read_exact(&mut scratch[..take])?;
            length -= take as u64;
        }
        Ok(())
    }
}

impl Drop for RfbReader {
    fn drop(&mut self) {
        self.plain.zeroize();
    }
}

/// The client-to-server half.
pub struct RfbWriter {
    inner: Box<dyn Write + Send>,
    encrypt: Option<EaxDirection>,
}

impl RfbWriter {
    pub fn new(inner: Box<dyn Write + Send>) -> Self {
        Self {
            inner,
            encrypt: None,
        }
    }

    pub fn encrypt_from_now(&mut self, direction: EaxDirection) {
        self.encrypt = Some(direction);
    }

    /// Send `data` as one write (one or more encrypted messages).
    pub fn send(&mut self, data: &[u8]) -> io::Result<()> {
        let Some(direction) = self.encrypt.as_mut() else {
            self.inner.write_all(data)?;
            return self.inner.flush();
        };
        let mut wire = Vec::with_capacity(data.len() + (data.len() / MAX_SEND_CHUNK + 1) * 18);
        for chunk in data.chunks(MAX_SEND_CHUNK) {
            let header = (chunk.len() as u16).to_be_bytes();
            let mut sealed = chunk.to_vec();
            let tag = direction.seal(&header, &mut sealed);
            wire.extend_from_slice(&header);
            wire.extend_from_slice(&sealed);
            wire.extend_from_slice(&tag);
        }
        self.inner.write_all(&wire)?;
        self.inner.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// EAX test vector 1 from Bellare, Rogaway and Wagner: an empty message
    /// with an empty header under this key and nonce.
    #[test]
    fn eax_matches_the_published_test_vector() {
        let key = [
            0x23, 0x39, 0x52, 0xDE, 0xE4, 0xD5, 0xED, 0x5F, 0x9B, 0x9C, 0x6D, 0x6F, 0xF8, 0x0F,
            0xF4, 0x78,
        ];
        let nonce = [
            0x62, 0xEC, 0x67, 0xF9, 0xC3, 0xA4, 0xA4, 0x07, 0xFC, 0xB2, 0xA8, 0xC4, 0x90, 0x31,
            0xA8, 0xB3,
        ];
        let header = [0x6B, 0xFB, 0x91, 0x4F, 0xD0, 0x7E, 0xAE, 0x6B];
        let cipher = Eax::<Aes128>::new(GenericArray::from_slice(&key));
        let mut data = Vec::new();
        let tag = cipher
            .encrypt_in_place_detached(GenericArray::from_slice(&nonce), &header, &mut data)
            .unwrap();
        assert_eq!(
            tag.as_slice(),
            [
                0xE0, 0x37, 0x83, 0x0E, 0x83, 0x89, 0xF2, 0x7B, 0x02, 0x5A, 0x2D, 0x65, 0x27, 0xE7,
                0x9D, 0x01
            ]
        );
    }

    #[test]
    fn nonces_count_up_little_endian_from_zero() {
        let mut direction = EaxDirection::new(&[7; 32]).unwrap();
        assert_eq!(direction.next_nonce(), [0; 16]);
        let mut one = [0_u8; 16];
        one[0] = 1;
        assert_eq!(direction.next_nonce(), one);
        direction.counter = 255;
        let mut carry = [0_u8; 16];
        carry[1] = 1;
        direction.next_nonce();
        assert_eq!(direction.next_nonce(), carry);
        assert!(EaxDirection::new(&[0; 24]).is_err());
    }

    #[derive(Clone, Default)]
    struct Shared(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);
    impl Write for Shared {
        fn write(&mut self, data: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(data);
            Ok(data.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn encrypted_messages_round_trip_across_message_boundaries() {
        let key = [9_u8; 32];
        let wire = Shared::default();
        let mut writer = RfbWriter::new(Box::new(wire.clone()));
        writer.encrypt_from_now(EaxDirection::new(&key).unwrap());
        let big: Vec<u8> = (0..10_000_u32).map(|i| i as u8).collect();
        writer.send(b"hello").unwrap();
        writer.send(&big).unwrap();
        let bytes = wire.0.lock().unwrap().clone();
        // 5 bytes, then 10 000 bytes in 4096-byte chunks: four messages.
        assert_eq!(bytes.len(), 5 + 10_000 + 4 * 18);
        assert_eq!(u16::from_be_bytes([bytes[0], bytes[1]]), 5);
        let mut reader = RfbReader::new(Box::new(Cursor::new(bytes.clone())));
        reader.encrypt_from_now(EaxDirection::new(&key).unwrap());
        let mut first = [0_u8; 3];
        reader.read_exact(&mut first).unwrap();
        assert_eq!(&first, b"hel");
        let mut rest = vec![0_u8; 2 + 10_000];
        reader.read_exact(&mut rest).unwrap();
        assert_eq!(&rest[..2], b"lo");
        assert_eq!(&rest[2..], &big[..]);
        // A flipped bit is refused.
        let mut tampered = bytes;
        tampered[4] ^= 1;
        let mut reader = RfbReader::new(Box::new(Cursor::new(tampered)));
        reader.encrypt_from_now(EaxDirection::new(&key).unwrap());
        let error = reader.read_exact(&mut first).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn lengths_are_bounded_before_allocation() {
        let mut reader = RfbReader::new(Box::new(Cursor::new(vec![0_u8; 8])));
        assert!(reader.bytes(1 << 30, 4096).is_err());
        assert_eq!(reader.bytes(4, 4096).unwrap(), [0; 4]);
        reader.skip(4).unwrap();
        assert!(reader.u8().is_err());
    }
}
