//! A scripted VNC server for tests: RSA-AES (as neatvnc implements it) or no
//! sign-in, then the updates a test supplies, recording what the client sent.

use crate::auth::{self, SecurityKind};
use crate::proto::{self, security};
use crate::stream::{EaxDirection, RfbReader, RfbWriter};
use rand_core::{OsRng, RngCore};
use rsa::{BigUint, Pkcs1v15Encrypt, RsaPrivateKey, RsaPublicKey};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::{self, JoinHandle};
use std::time::Duration;

/// One 1024-bit server key for every test, generated once.
fn server_key() -> &'static RsaPrivateKey {
    static KEY: OnceLock<RsaPrivateKey> = OnceLock::new();
    KEY.get_or_init(|| RsaPrivateKey::new(&mut OsRng, 1024).unwrap())
}

#[derive(Clone)]
pub struct Script {
    pub offered: Vec<u8>,
    pub username: String,
    pub password: Vec<u8>,
    pub width: u16,
    pub height: u16,
    /// Server messages, one sent per update request from the client.
    pub updates: Vec<Vec<u8>>,
    /// Corrupt the server hash, as a tampering middlebox would.
    pub bad_server_hash: bool,
}

impl Default for Script {
    fn default() -> Self {
        Self {
            offered: vec![security::RA2_256, security::RA2, security::APPLE_DH],
            username: "alex".into(),
            password: b"correct horse".to_vec(),
            width: 64,
            height: 32,
            updates: Vec::new(),
            bad_server_hash: false,
        }
    }
}

#[derive(Debug, Default, Clone)]
pub struct Record {
    pub chosen: Option<u8>,
    pub username: Option<String>,
    /// Whether the right password arrived; the password itself is not kept.
    pub password_matched: Option<bool>,
    pub shared_flag: Option<u8>,
    pub pixel_format: Option<[u8; 16]>,
    pub encodings: Vec<i32>,
    pub update_requests: Vec<[u8; 10]>,
    /// (down, keysym)
    pub keys: Vec<(bool, u32)>,
    /// (buttons, x, y)
    pub pointer: Vec<(u8, u16, u16)>,
    pub closed_by_client: bool,
}

pub struct FakeServer {
    pub port: u16,
    pub record: Arc<Mutex<Record>>,
    handle: Option<JoinHandle<Result<(), String>>>,
}

impl FakeServer {
    pub fn start(script: Script) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let record = Arc::new(Mutex::new(Record::default()));
        let shared = Arc::clone(&record);
        let handle = thread::spawn(move || {
            let (stream, _) = listener.accept().map_err(|e| e.to_string())?;
            stream
                .set_read_timeout(Some(Duration::from_secs(30)))
                .unwrap();
            serve(stream, &script, &shared)
        });
        Self {
            port,
            record,
            handle: Some(handle),
        }
    }

    pub fn record(&self) -> Record {
        self.record.lock().unwrap().clone()
    }

    /// Wait until the record satisfies `ready`, up to five seconds.
    pub fn wait_for(&self, ready: impl Fn(&Record) -> bool) -> Record {
        for _ in 0..500 {
            let record = self.record();
            if ready(&record) {
                return record;
            }
            thread::sleep(Duration::from_millis(10));
        }
        panic!("timed out waiting; record: {:?}", self.record());
    }

    pub fn finish(mut self) -> Result<(), String> {
        self.handle.take().unwrap().join().unwrap()
    }
}

fn serve(stream: TcpStream, script: &Script, record: &Mutex<Record>) -> Result<(), String> {
    let mut reader = RfbReader::new(Box::new(stream.try_clone().unwrap()));
    let mut writer = RfbWriter::new(Box::new(stream.try_clone().unwrap()));
    let err = |e: std::io::Error| e.to_string();
    writer.send(b"RFB 003.008\n").map_err(err)?;
    let mut version = [0_u8; 12];
    reader.read_exact(&mut version).map_err(err)?;
    if &version != b"RFB 003.008\n" {
        return Err(format!("client version {version:?}"));
    }
    let mut list = vec![script.offered.len() as u8];
    list.extend_from_slice(&script.offered);
    writer.send(&list).map_err(err)?;
    let chosen = reader.u8().map_err(err)?;
    record.lock().unwrap().chosen = Some(chosen);
    let accepted = match chosen {
        security::NONE => {
            writer.send(&0_u32.to_be_bytes()).map_err(err)?;
            true
        }
        security::RA2 | security::RA2_256 => {
            let kind = if chosen == security::RA2_256 {
                SecurityKind::RsaAes256
            } else {
                SecurityKind::RsaAes128
            };
            let random_len = if chosen == security::RA2_256 { 32 } else { 16 };
            let key = server_key();
            let server_message = auth::key_message(&RsaPublicKey::from(key));
            writer.send(&server_message).map_err(err)?;
            let bits = reader.u32().map_err(err)?;
            let length = bits.div_ceil(8) as usize;
            let mut client_message = bits.to_be_bytes().to_vec();
            client_message.resize(4 + length * 2, 0);
            reader.read_exact(&mut client_message[4..]).map_err(err)?;
            let client_key = RsaPublicKey::new(
                BigUint::from_bytes_be(&client_message[4..4 + length]),
                BigUint::from_bytes_be(&client_message[4 + length..]),
            )
            .map_err(|e| e.to_string())?;
            let mut server_random = vec![0_u8; random_len];
            OsRng.fill_bytes(&mut server_random);
            let encrypted = client_key
                .encrypt(&mut OsRng, Pkcs1v15Encrypt, &server_random)
                .unwrap();
            let mut message = (encrypted.len() as u16).to_be_bytes().to_vec();
            message.extend_from_slice(&encrypted);
            writer.send(&message).map_err(err)?;
            let length = reader.u16().map_err(err)?;
            let encrypted = reader.bytes(u32::from(length), 1024).map_err(err)?;
            let client_random = key
                .decrypt(Pkcs1v15Encrypt, &encrypted)
                .map_err(|e| e.to_string())?;
            let client_session = auth::hash(kind, &[&server_random, &client_random]);
            let server_session = auth::hash(kind, &[&client_random, &server_random]);
            let key_len = if chosen == security::RA2_256 { 32 } else { 16 };
            writer.encrypt_from_now(EaxDirection::new(&server_session[..key_len]).unwrap());
            reader.encrypt_from_now(EaxDirection::new(&client_session[..key_len]).unwrap());
            let mut server_hash = auth::hash(kind, &[&server_message, &client_message]).to_vec();
            if script.bad_server_hash {
                server_hash[0] ^= 1;
            }
            writer.send(&server_hash).map_err(err)?;
            let expected = auth::hash(kind, &[&client_message, &server_message]);
            let mut client_hash = vec![0_u8; expected.len()];
            reader.read_exact(&mut client_hash).map_err(err)?;
            if client_hash != *expected {
                return Err("client hash mismatch".into());
            }
            writer.send(&[1]).map_err(err)?;
            let username_len = reader.u8().map_err(err)?;
            let username = reader.bytes(u32::from(username_len), 255).map_err(err)?;
            let password_len = reader.u8().map_err(err)?;
            let password = reader.bytes(u32::from(password_len), 255).map_err(err)?;
            let username = String::from_utf8(username).unwrap();
            let ok = username == script.username && password == script.password;
            {
                let mut record = record.lock().unwrap();
                record.username = Some(username);
                record.password_matched = Some(password == script.password);
            }
            if ok {
                writer.send(&0_u32.to_be_bytes()).map_err(err)?;
            } else {
                let reason = b"Authentication failed";
                let mut message = 1_u32.to_be_bytes().to_vec();
                message.extend_from_slice(&(reason.len() as u32).to_be_bytes());
                message.extend_from_slice(reason);
                writer.send(&message).map_err(err)?;
            }
            ok
        }
        other => return Err(format!("client chose {other}")),
    };
    if !accepted {
        return Ok(());
    }
    record.lock().unwrap().shared_flag = Some(reader.u8().map_err(err)?);
    let mut init = Vec::new();
    init.extend_from_slice(&script.width.to_be_bytes());
    init.extend_from_slice(&script.height.to_be_bytes());
    let mut server_format = proto::PixelFormat::BGRX;
    server_format.red_shift = 0;
    server_format.blue_shift = 16;
    init.extend_from_slice(&server_format.encode());
    let name = b"alex's Omarchy desktop";
    init.extend_from_slice(&(name.len() as u32).to_be_bytes());
    init.extend_from_slice(name);
    writer.send(&init).map_err(err)?;
    let mut updates = script.updates.iter();
    loop {
        let message = match reader.u8() {
            Ok(message) => message,
            Err(_) => {
                record.lock().unwrap().closed_by_client = true;
                return Ok(());
            }
        };
        match message {
            0 => {
                let mut body = [0_u8; 19];
                reader.read_exact(&mut body).map_err(err)?;
                record.lock().unwrap().pixel_format = Some(body[3..19].try_into().unwrap());
            }
            2 => {
                let _ = reader.u8().map_err(err)?;
                let count = reader.u16().map_err(err)?;
                let mut list = Vec::new();
                for _ in 0..count {
                    list.push(reader.i32().map_err(err)?);
                }
                record.lock().unwrap().encodings = list;
            }
            3 => {
                let mut body = [0_u8; 9];
                reader.read_exact(&mut body).map_err(err)?;
                let mut request = [3_u8; 10];
                request[1..].copy_from_slice(&body);
                record.lock().unwrap().update_requests.push(request);
                if let Some(update) = updates.next() {
                    writer.send(update).map_err(err)?;
                }
            }
            4 => {
                let down = reader.u8().map_err(err)? != 0;
                let _ = reader.u16().map_err(err)?;
                let keysym = reader.u32().map_err(err)?;
                record.lock().unwrap().keys.push((down, keysym));
            }
            5 => {
                let buttons = reader.u8().map_err(err)?;
                let x = reader.u16().map_err(err)?;
                let y = reader.u16().map_err(err)?;
                record.lock().unwrap().pointer.push((buttons, x, y));
            }
            other => return Err(format!("unexpected client message {other}")),
        }
    }
}

/// One rectangle: x, y, width, height, encoding and its body.
pub type TestRect = (u16, u16, u16, u16, i32, Vec<u8>);

/// A FramebufferUpdate message from rectangles.
pub fn update(rects: &[TestRect]) -> Vec<u8> {
    let mut out = vec![0_u8, 0];
    out.extend_from_slice(&(rects.len() as u16).to_be_bytes());
    for (x, y, w, h, encoding, body) in rects {
        for value in [x, y, w, h] {
            out.extend_from_slice(&value.to_be_bytes());
        }
        out.extend_from_slice(&encoding.to_be_bytes());
        out.extend_from_slice(body);
    }
    out
}
