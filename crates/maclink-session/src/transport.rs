//! Sockets, Noise handshake, bounded framing, the handle registry and typed
//! session messages.
//!
//! Each TCP record has a two-byte big-endian ciphertext length. Application
//! plaintext contains version byte 1, type byte, two reserved zero bytes,
//! big-endian u64 message sequence, u32 total payload length and u32 chunk
//! offset, followed by the chunk. Nothing about a record is interpreted before
//! it authenticates.

use crate::clipboard::{self, ClipboardKind, ClipboardPacket, MAX_CLIPBOARD};
use crate::control::ControlMessage;
use crate::input::InputEvent;
use crate::policy::{Admission, CLIPBOARD, CONTROL, INPUT, ReceivePolicy, Role, TELEMETRY, VIDEO};
use crate::telemetry::{MAX_TELEMETRY, TelemetryMessage};
use crate::video::{VideoFrame, VideoPacket};
use crate::{Error, Result};
use snow::{Builder, HandshakeState, StatelessTransportState};
use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{IpAddr, Shutdown, SocketAddr, TcpListener, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, mpsc};
use std::time::{Duration, Instant};
use zeroize::{Zeroize, Zeroizing};

pub(crate) const PATTERN: &str = "Noise_NKpsk0_25519_ChaChaPoly_BLAKE2s";
pub(crate) const PROLOGUE: &[u8] = b"MacLink direct session v1";
/// Names the application message formats; mismatched builds fail the handshake.
pub(crate) const HANDSHAKE_PAYLOAD: &[u8] = b"maclink-session/4";
pub(crate) const MAX_VIDEO: usize = crate::video::MAX_PACKET;
pub(crate) const MAX_INPUT: usize = 256;
pub(crate) const MAX_CONTROL: usize = 1024;
const SMALL_MESSAGE: usize = MAX_CONTROL;
pub(crate) const MAX_RECORD: usize = 65535;
const HEADER: usize = 20;
const CHUNK: usize = MAX_RECORD - 16 - HEADER;
const MAX_HANDLES: usize = 128;
/// A connection accepted near the end of an accept window still gets this long
/// to authenticate, so a legitimate viewer is not dropped mid-handshake.
const HANDSHAKE_GRACE: Duration = Duration::from_secs(1);
const MAX_RESOLVERS: usize = 4;
/// Once a message's first byte arrives it may take this long to finish, even
/// past the caller's receive deadline, which bounds only the wait for a new
/// message. A message still incomplete after this ends the session.
pub(crate) const MESSAGE_GRACE: Duration = Duration::from_secs(10);

pub(crate) fn deadline(milliseconds: u32) -> Result<Instant> {
    if !(1..=30000).contains(&milliseconds) {
        return Err(Error::Invalid);
    }
    Ok(Instant::now() + Duration::from_millis(milliseconds.into()))
}
fn remaining(end: Instant) -> Result<Duration> {
    end.checked_duration_since(Instant::now())
        .filter(|time| !time.is_zero())
        .ok_or(Error::Timeout)
}
fn lock<T>(mutex: &Mutex<T>) -> Result<MutexGuard<'_, T>> {
    mutex.lock().map_err(|_| Error::Internal)
}
fn direction<T>(mutex: &Mutex<T>) -> Result<MutexGuard<'_, T>> {
    mutex.try_lock().map_err(|error| match error {
        std::sync::TryLockError::WouldBlock => Error::Busy,
        std::sync::TryLockError::Poisoned(_) => Error::Internal,
    })
}
fn limit(kind: u8) -> Result<usize> {
    match kind {
        VIDEO => Ok(MAX_VIDEO),
        INPUT => Ok(MAX_INPUT),
        CONTROL => Ok(MAX_CONTROL),
        TELEMETRY => Ok(MAX_TELEMETRY),
        CLIPBOARD => Ok(MAX_CLIPBOARD),
        _ => Err(Error::Invalid),
    }
}
fn io_error(error: io::Error) -> Error {
    match error.kind() {
        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => Error::Timeout,
        io::ErrorKind::UnexpectedEof
        | io::ErrorKind::BrokenPipe
        | io::ErrorKind::ConnectionAborted
        | io::ErrorKind::ConnectionReset => Error::Closed,
        _ => Error::Io,
    }
}

/// The first byte of a message extends `end` to at least `grace` from now.
fn read_exact(
    stream: &TcpStream,
    mut output: &mut [u8],
    end: &mut Instant,
    grace: Duration,
    progress: &mut usize,
) -> Result<()> {
    let mut reader = stream;
    while !output.is_empty() {
        stream
            .set_read_timeout(Some(remaining(*end)?))
            .map_err(io_error)?;
        match reader.read(output) {
            Ok(0) => return Err(Error::Closed),
            Ok(count) => {
                if *progress == 0 {
                    *end = (*end).max(Instant::now() + grace);
                }
                *progress += count;
                output = &mut output[count..];
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(io_error(error)),
        }
    }
    Ok(())
}
pub(crate) fn write_exact(stream: &TcpStream, mut input: &[u8], end: Instant) -> Result<()> {
    let mut writer = stream;
    while !input.is_empty() {
        stream
            .set_write_timeout(Some(remaining(end)?))
            .map_err(io_error)?;
        match writer.write(input) {
            Ok(0) => return Err(Error::Closed),
            Ok(count) => input = &input[count..],
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(io_error(error)),
        }
    }
    Ok(())
}
pub(crate) fn read_record(
    stream: &TcpStream,
    output: &mut [u8],
    mut end: Instant,
    progress: &mut usize,
) -> Result<usize> {
    read_record_within(stream, output, &mut end, Duration::ZERO, progress)
}
fn read_record_within(
    stream: &TcpStream,
    output: &mut [u8],
    end: &mut Instant,
    grace: Duration,
    progress: &mut usize,
) -> Result<usize> {
    let mut prefix = [0_u8; 2];
    read_exact(stream, &mut prefix, end, grace, progress)?;
    let size = usize::from(u16::from_be_bytes(prefix));
    // The unauthenticated wire length can only select a bounded stack slice.
    if size < 16 || size > output.len() {
        return Err(Error::Protocol);
    }
    read_exact(stream, &mut output[..size], end, grace, progress)?;
    Ok(size)
}
pub(crate) fn write_record(stream: &TcpStream, data: &[u8], end: Instant) -> Result<()> {
    let size = u16::try_from(data.len()).map_err(|_| Error::Protocol)?;
    write_exact(stream, &size.to_be_bytes(), end)?;
    write_exact(stream, data, end)
}

pub(crate) fn builder<'a>() -> Result<Builder<'a>> {
    Ok(Builder::new(PATTERN.parse().map_err(|_| Error::Internal)?))
}
fn handshake(
    mut noise: HandshakeState,
    stream: &TcpStream,
    initiator: bool,
    end: Instant,
) -> Result<StatelessTransportState> {
    stream.set_nodelay(true).map_err(io_error)?;
    let mut incoming = [0_u8; 1024];
    let mut outgoing = [0_u8; 1024];
    let mut payload = [0_u8; 1024];
    for send in [initiator, !initiator] {
        if send {
            let size = noise
                .write_message(HANDSHAKE_PAYLOAD, &mut outgoing)
                .map_err(|_| Error::Auth)?;
            write_record(stream, &outgoing[..size], end)?;
        } else {
            let size = read_record(stream, &mut incoming, end, &mut 0)?;
            let count = noise
                .read_message(&incoming[..size], &mut payload)
                .map_err(|_| Error::Auth)?;
            if &payload[..count] != HANDSHAKE_PAYLOAD {
                return Err(Error::Protocol);
            }
        }
    }
    if !noise.is_handshake_finished() {
        return Err(Error::Auth);
    }
    let crypto = noise
        .into_stateless_transport_mode()
        .map_err(|_| Error::Auth)?;
    // Confirm fresh transport keys in both directions before exposing a handle.
    // Replaying a valid first Noise message cannot start a host session.
    for send in [initiator, !initiator] {
        if send {
            let label: &[u8] = if initiator {
                b"client-ready/1"
            } else {
                b"server-ready/1"
            };
            let size = crypto
                .write_message(0, label, &mut outgoing)
                .map_err(|_| Error::Auth)?;
            write_record(stream, &outgoing[..size], end)?;
        } else {
            let label: &[u8] = if initiator {
                b"server-ready/1"
            } else {
                b"client-ready/1"
            };
            let size = read_record(stream, &mut incoming, end, &mut 0)?;
            let count = crypto
                .read_message(0, &incoming[..size], &mut payload)
                .map_err(|_| Error::Auth)?;
            if &payload[..count] != label {
                return Err(Error::Auth);
            }
        }
    }
    Ok(crypto)
}

pub(crate) enum Outgoing<'a> {
    Video(VideoFrame<'a>),
    Input(InputEvent),
    Control(ControlMessage),
    Telemetry(TelemetryMessage),
    Clipboard(&'a [(ClipboardKind, &'a [u8])]),
}
#[derive(Debug, PartialEq)]
pub(crate) enum Incoming {
    /// Component ranges index the caller's large-message buffer.
    Video(VideoPacket),
    Input(InputEvent),
    Control(ControlMessage),
    Telemetry(TelemetryMessage),
    /// Representation ranges index the caller's large-message buffer.
    Clipboard(ClipboardPacket),
}
/// Video and clipboard arrive in the caller's buffer; the rest on the stack.
fn is_large(kind: u8) -> bool {
    matches!(kind, VIDEO | CLIPBOARD)
}

pub(crate) struct Counter {
    nonce: u64,
    message: u64,
}
impl Default for Counter {
    fn default() -> Self {
        Self {
            nonce: 1,
            message: 0,
        }
    }
}
pub(crate) struct Inbound {
    counter: Counter,
    pub(crate) policy: ReceivePolicy,
    pub(crate) grace: Duration,
}
pub(crate) struct Session {
    pub(crate) socket: TcpStream,
    pub(crate) crypto: StatelessTransportState,
    pub(crate) role: Role,
    send: Mutex<Counter>,
    pub(crate) receive: Mutex<Inbound>,
    pub(crate) closed: AtomicBool,
}
impl Session {
    fn new(socket: TcpStream, crypto: StatelessTransportState, role: Role) -> Self {
        Self {
            socket,
            crypto,
            role,
            send: Mutex::new(Counter::default()),
            receive: Mutex::new(Inbound {
                counter: Counter::default(),
                policy: ReceivePolicy::new(role, Instant::now()),
                grace: MESSAGE_GRACE,
            }),
            closed: AtomicBool::new(false),
        }
    }
    pub(crate) fn close(&self) {
        self.closed.store(true, Ordering::Release);
        let _ = self.socket.shutdown(Shutdown::Both);
    }
    fn check_open(&self) -> Result<()> {
        if self.closed.load(Ordering::Acquire) {
            Err(Error::Closed)
        } else {
            Ok(())
        }
    }

    /// Invalid or misdirected messages fail before any byte is written and do
    /// not close the session. A failed write closes it: frames cannot resume.
    pub(crate) fn send_message(&self, message: &Outgoing<'_>, end: Instant) -> Result<()> {
        match message {
            Outgoing::Video(frame) => self.send_bytes(VIDEO, &frame.encode()?, end),
            Outgoing::Input(event) => self.send_bytes(INPUT, &event.encode(), end),
            Outgoing::Control(control) if self.role.may_send_control(control.kind()) => {
                self.send_bytes(CONTROL, &control.encode(), end)
            }
            Outgoing::Control(_) => Err(Error::Invalid),
            Outgoing::Telemetry(telemetry) if self.role.may_send_telemetry(telemetry) => {
                self.send_bytes(TELEMETRY, &telemetry.encode()?, end)
            }
            Outgoing::Telemetry(_) => Err(Error::Invalid),
            Outgoing::Clipboard(items) => {
                self.send_bytes(CLIPBOARD, &clipboard::encode(items)?, end)
            }
        }
    }
    pub(crate) fn send_bytes(&self, kind: u8, data: &[u8], end: Instant) -> Result<()> {
        if !self.role.may_send(kind) || data.len() > limit(kind)? {
            return Err(Error::Invalid);
        }
        self.check_open()?;
        let mut counter = direction(&self.send)?;
        let result = (|| {
            let mut plain = [0_u8; MAX_RECORD];
            let mut encrypted = [0_u8; MAX_RECORD];
            let mut offset = 0;
            loop {
                self.check_open()?;
                let count = CHUNK.min(data.len() - offset);
                plain[0] = 1;
                plain[1] = kind;
                plain[2..4].fill(0);
                plain[4..12].copy_from_slice(&counter.message.to_be_bytes());
                plain[12..16].copy_from_slice(&(data.len() as u32).to_be_bytes());
                plain[16..20].copy_from_slice(&(offset as u32).to_be_bytes());
                plain[HEADER..HEADER + count].copy_from_slice(&data[offset..offset + count]);
                let size = self
                    .crypto
                    .write_message(counter.nonce, &plain[..HEADER + count], &mut encrypted)
                    .map_err(|_| Error::Auth)?;
                counter.nonce = counter.nonce.checked_add(1).ok_or(Error::Protocol)?;
                write_record(&self.socket, &encrypted[..size], end)?;
                offset += count;
                if offset == data.len() {
                    break;
                }
            }
            counter.message = counter.message.checked_add(1).ok_or(Error::Protocol)?;
            Ok(())
        })();
        if result.is_err() {
            self.close();
        }
        result
    }

    /// Receive one typed message. Video and clipboard land in the caller's
    /// buffer; input, control and telemetry use a fixed stack buffer. Messages
    /// the policy spaces out are consumed and skipped within the same deadline.
    pub(crate) fn receive_message(&self, video: &mut [u8], end: Instant) -> Result<Incoming> {
        self.check_open()?;
        let mut inbound = direction(&self.receive)?;
        let Inbound {
            counter,
            policy,
            grace,
        } = &mut *inbound;
        let mut small = [0_u8; SMALL_MESSAGE];
        loop {
            let (kind, length) =
                match self.receive_locked(counter, video, &mut small, end, *grace, &mut 0) {
                    Err(Error::Timeout) if policy.is_idle(Instant::now()) => {
                        self.close();
                        return Err(Error::Stalled);
                    }
                    other => other?,
                };
            let decoded = (|| {
                let message = match kind {
                    VIDEO => Incoming::Video(VideoPacket::parse(&video[..length])?),
                    CLIPBOARD => Incoming::Clipboard(ClipboardPacket::parse(&video[..length])?),
                    INPUT => Incoming::Input(InputEvent::decode(&small[..length])?),
                    CONTROL => Incoming::Control(ControlMessage::decode(&small[..length])?),
                    _ => Incoming::Telemetry(TelemetryMessage::decode(&small[..length])?),
                };
                Ok((policy.admit(&message, Instant::now())?, message))
            })();
            match decoded {
                Ok((Admission::Deliver, message)) => return Ok(message),
                Ok((Admission::Skip, _)) => continue,
                Err(error) => {
                    if is_large(kind) {
                        video[..length].zeroize()
                    } else {
                        small[..length].zeroize()
                    }
                    self.close();
                    return Err(error);
                }
            }
        }
    }

    /// Untyped receive, used by transport tests.
    #[cfg(test)]
    pub(crate) fn receive_bytes(
        &self,
        video: &mut [u8],
        small: &mut [u8],
        end: Instant,
        needed: &mut usize,
    ) -> Result<(u8, usize)> {
        self.check_open()?;
        let mut inbound = direction(&self.receive)?;
        let grace = inbound.grace;
        self.receive_locked(&mut inbound.counter, video, small, end, grace, needed)
    }

    fn receive_locked(
        &self,
        counter: &mut Counter,
        video: &mut [u8],
        small: &mut [u8],
        mut end: Instant,
        grace: Duration,
        needed: &mut usize,
    ) -> Result<(u8, usize)> {
        let mut progress = 0;
        let mut offset = 0;
        let mut expected: Option<(u8, usize)> = None;
        let result = (|| {
            let mut encrypted = [0_u8; MAX_RECORD];
            let mut plain = [0_u8; MAX_RECORD];
            loop {
                self.check_open()?;
                let size = read_record_within(
                    &self.socket,
                    &mut encrypted,
                    &mut end,
                    grace,
                    &mut progress,
                )?;
                let count = self
                    .crypto
                    .read_message(counter.nonce, &encrypted[..size], &mut plain)
                    .map_err(|_| Error::Auth)?;
                counter.nonce = counter.nonce.checked_add(1).ok_or(Error::Protocol)?;
                // No application type, total length, sequence or offset is used
                // before the entire encrypted record has authenticated.
                if count < HEADER || plain[0] != 1 || plain[2..4] != [0, 0] {
                    return Err(Error::Protocol);
                }
                let kind = plain[1];
                let sequence =
                    u64::from_be_bytes(plain[4..12].try_into().map_err(|_| Error::Protocol)?);
                let total =
                    u32::from_be_bytes(plain[12..16].try_into().map_err(|_| Error::Protocol)?)
                        as usize;
                let position =
                    u32::from_be_bytes(plain[16..20].try_into().map_err(|_| Error::Protocol)?)
                        as usize;
                let payload = count - HEADER;
                // Direction is checked on the first chunk, before a peer can make
                // this side buffer a message it may never receive.
                if !self.role.may_receive(kind)
                    || sequence != counter.message
                    || total > limit(kind).map_err(|_| Error::Protocol)?
                    || position != offset
                    || payload > total.saturating_sub(offset)
                    || (payload == 0 && total != 0)
                    || expected.is_some_and(|value| value != (kind, total))
                {
                    return Err(Error::Protocol);
                }
                let output: &mut [u8] = if is_large(kind) {
                    &mut *video
                } else {
                    &mut *small
                };
                if total > output.len() {
                    *needed = total;
                    return Err(Error::Buffer);
                }
                expected = Some((kind, total));
                output[offset..offset + payload].copy_from_slice(&plain[HEADER..count]);
                offset += payload;
                if offset == total {
                    counter.message = counter.message.checked_add(1).ok_or(Error::Protocol)?;
                    *needed = total;
                    return Ok((kind, total));
                }
            }
        })();
        match result {
            Err(Error::Timeout) if progress == 0 => Err(Error::Timeout),
            Err(error) => {
                if let Some((kind, _)) = expected {
                    let output: &mut [u8] = if is_large(kind) { video } else { small };
                    output[..offset].zeroize();
                }
                self.close();
                // Partial frames cannot be retried: counters and framing may
                // have advanced, and no plaintext is published to the caller.
                // A message still incomplete after its grace period has stalled.
                Err(if error == Error::Timeout {
                    Error::Stalled
                } else {
                    error
                })
            }
            success => success,
        }
    }
}

pub(crate) struct Listener {
    pub(crate) socket: TcpListener,
    private: Zeroizing<[u8; 32]>,
    psk: Zeroizing<[u8; 32]>,
    pub(crate) closed: AtomicBool,
    accepting: Mutex<()>,
    pending: Mutex<Option<TcpStream>>,
}
impl Listener {
    pub(crate) fn bind(
        address: SocketAddr,
        private: Zeroizing<[u8; 32]>,
        psk: Zeroizing<[u8; 32]>,
    ) -> Result<Self> {
        let socket = TcpListener::bind(address).map_err(io_error)?;
        socket.set_nonblocking(true).map_err(io_error)?;
        Ok(Self {
            socket,
            private,
            psk,
            closed: AtomicBool::new(false),
            accepting: Mutex::new(()),
            pending: Mutex::new(None),
        })
    }
    fn close(&self) {
        self.closed.store(true, Ordering::Release);
        if let Ok(pending) = self.pending.lock()
            && let Some(socket) = pending.as_ref()
        {
            let _ = socket.shutdown(Shutdown::Both);
        }
    }
    pub(crate) fn accept(&self, end: Instant) -> Result<Arc<Session>> {
        let _accepting = direction(&self.accepting)?;
        let socket = loop {
            if self.closed.load(Ordering::Acquire) {
                return Err(Error::Closed);
            }
            remaining(end)?;
            match self.socket.accept() {
                Ok((socket, _)) => break socket,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(5))
                }
                Err(error) => return Err(io_error(error)),
            }
        };
        socket.set_nonblocking(false).map_err(io_error)?;
        let end = end.max(Instant::now() + HANDSHAKE_GRACE);
        *lock(&self.pending)? = Some(socket.try_clone().map_err(io_error)?);
        let result = (|| {
            if self.closed.load(Ordering::Acquire) {
                return Err(Error::Closed);
            }
            let noise = builder()?
                .local_private_key(&*self.private)
                .map_err(|_| Error::Auth)?
                .psk(0, &self.psk)
                .map_err(|_| Error::Auth)?
                .prologue(PROLOGUE)
                .map_err(|_| Error::Auth)?
                .build_responder()
                .map_err(|_| Error::Auth)?;
            let crypto = handshake(noise, &socket, false, end)?;
            if self.closed.load(Ordering::Acquire) {
                return Err(Error::Closed);
            }
            Ok(Arc::new(Session::new(socket, crypto, Role::Host)))
        })();
        lock(&self.pending)?.take();
        result
    }
}

#[derive(Clone)]
pub(crate) enum Handle {
    Listener(Arc<Listener>),
    Session(Arc<Session>),
}
impl Handle {
    fn close(&self) {
        match self {
            Self::Listener(value) => value.close(),
            Self::Session(value) => value.close(),
        }
    }
}
static REGISTRY: OnceLock<Mutex<HashMap<u64, Handle>>> = OnceLock::new();
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static RESOLVERS: AtomicUsize = AtomicUsize::new(0);
fn registry() -> &'static Mutex<HashMap<u64, Handle>> {
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}
pub(crate) fn insert(value: Handle, parent: Option<&Listener>) -> Result<u64> {
    let mut table = lock(registry())?;
    if parent.is_some_and(|listener| listener.closed.load(Ordering::Acquire)) {
        value.close();
        return Err(Error::Closed);
    }
    if table.len() >= MAX_HANDLES {
        value.close();
        return Err(Error::Busy);
    }
    let id = NEXT_ID
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |value| {
            value.checked_add(1)
        })
        .map_err(|_| Error::Internal)?;
    table.insert(id, value);
    Ok(id)
}
pub(crate) fn session(id: u64) -> Result<Arc<Session>> {
    match lock(registry())?.get(&id) {
        Some(Handle::Session(value)) => Ok(value.clone()),
        _ => Err(Error::Closed),
    }
}
pub(crate) fn listener(id: u64) -> Result<Arc<Listener>> {
    match lock(registry())?.get(&id) {
        Some(Handle::Listener(value)) => Ok(value.clone()),
        _ => Err(Error::Closed),
    }
}
/// Closing under the registry lock serializes accepted-handle publication with
/// listener cancellation. In-flight calls retain an Arc, never a freed pointer;
/// shutdown interrupts their blocking socket operations.
pub(crate) fn close(id: u64) -> Result<()> {
    let mut table = lock(registry())?;
    let value = table.remove(&id).ok_or(Error::Closed)?;
    value.close();
    Ok(())
}

fn resolve(host: &str, port: u16, end: Instant) -> Result<Vec<SocketAddr>> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(vec![SocketAddr::new(ip, port)]);
    }
    // System DNS can block indefinitely. Bound detached resolver count and the
    // caller's wait; timed-out workers cannot accumulate without limit.
    RESOLVERS
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < MAX_RESOLVERS).then_some(count + 1)
        })
        .map_err(|_| Error::Busy)?;
    let host = host.to_owned();
    let (tx, rx) = mpsc::sync_channel(1);
    let spawned = std::thread::Builder::new()
        .name("maclink-resolver".into())
        .spawn(move || {
            let result = (host.as_str(), port)
                .to_socket_addrs()
                .map(|addresses| addresses.take(8).collect::<Vec<_>>())
                .map_err(io_error);
            RESOLVERS.fetch_sub(1, Ordering::AcqRel);
            let _ = tx.send(result);
        });
    if spawned.is_err() {
        RESOLVERS.fetch_sub(1, Ordering::AcqRel);
        return Err(Error::Internal);
    }
    rx.recv_timeout(remaining(end)?)
        .map_err(|_| Error::Timeout)?
}
/// `host` must already be normalized by the shared host rule.
pub(crate) fn connect(
    host: &str,
    port: u16,
    public: &[u8; 32],
    psk: &[u8; 32],
    end: Instant,
) -> Result<Arc<Session>> {
    if port == 0 {
        return Err(Error::Invalid);
    }
    let mut last = Error::Io;
    for address in resolve(host, port, end)? {
        let socket = match TcpStream::connect_timeout(&address, remaining(end)?) {
            Ok(socket) => socket,
            Err(error) => {
                last = io_error(error);
                continue;
            }
        };
        let noise = builder()?
            .remote_public_key(public)
            .map_err(|_| Error::Auth)?
            .psk(0, psk)
            .map_err(|_| Error::Auth)?
            .prologue(PROLOGUE)
            .map_err(|_| Error::Auth)?
            .build_initiator()
            .map_err(|_| Error::Auth)?;
        let crypto = handshake(noise, &socket, true, end)?;
        return Ok(Arc::new(Session::new(socket, crypto, Role::Viewer)));
    }
    Err(last)
}
