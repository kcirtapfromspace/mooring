//! One viewer session: connect, sign in once, then decode updates into the
//! framebuffer while a second thread sends input.
//!
//! Bounded throughout: the event queue, the input queue (pointer moves are
//! merged; an overflowing queue releases every held key rather than leave
//! one stuck), every length the server sends, and every wait. Stopping
//! releases held keys and buttons, then closes the socket, which ends both
//! threads.

use crate::auth::{
    self, AuthError, AuthErrorKind, Credentials, Negotiated, SecurityKind, client_key,
    ra2_handshake, read_security_result, send_credentials,
};
use crate::framebuffer::{BYTES_PER_PIXEL, Framebuffer, Rect};
use crate::keysym::HeldKeys;
use crate::proto::{self, PixelFormat, encoding};
use crate::stream::{RfbReader, RfbWriter};
use crate::zrle::{MAX_COMPRESSED_BYTES, ZrleDecoder};
use rsa::RsaPrivateKey;
use serde::Serialize;
use std::collections::VecDeque;
use std::io;
use std::net::{Shutdown, SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// The largest desktop accepted: 8192 x 4608 pixels (151 MB of BGRX).
pub const MAX_PIXELS: usize = 8192 * 4608;
const MAX_EVENTS: usize = 64;
const MAX_QUEUED_INPUT: usize = 512;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(20);
const WRITE_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Debug)]
pub struct SessionConfig {
    pub host: String,
    pub port: u16,
    pub connect_timeout: Duration,
    /// Stop when the server asks for credentials, without sending any. Used
    /// to check a route and its encryption with no sign-in attempt.
    pub check_only: bool,
    pub client_key_bits: usize,
}

impl SessionConfig {
    pub fn new(host: &str, port: u16) -> Self {
        Self {
            host: host.to_owned(),
            port,
            connect_timeout: Duration::from_secs(10),
            check_only: false,
            client_key_bits: auth::CLIENT_KEY_BITS,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionErrorKind {
    ConnectFailed,
    NotVnc,
    UnsupportedVersion,
    ServerRefused,
    UnsupportedSecurity,
    HandshakeFailed,
    CredentialsNeeded,
    /// The server rejected the username or password.
    SignInRejected,
    ProtocolError,
    ConnectionLost,
    TimedOut,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SessionError {
    pub kind: SessionErrorKind,
    pub message: String,
}

impl SessionError {
    fn new(kind: SessionErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    fn protocol(message: impl Into<String>) -> Self {
        Self::new(SessionErrorKind::ProtocolError, message)
    }
}

impl From<AuthError> for SessionError {
    fn from(error: AuthError) -> Self {
        let kind = match error.kind {
            AuthErrorKind::NotVnc => SessionErrorKind::NotVnc,
            AuthErrorKind::UnsupportedVersion => SessionErrorKind::UnsupportedVersion,
            AuthErrorKind::ServerRefused => SessionErrorKind::ServerRefused,
            AuthErrorKind::UnsupportedSecurity => SessionErrorKind::UnsupportedSecurity,
            AuthErrorKind::HandshakeFailed => SessionErrorKind::HandshakeFailed,
            AuthErrorKind::SignInRejected => SessionErrorKind::SignInRejected,
            AuthErrorKind::CredentialsNeeded => SessionErrorKind::CredentialsNeeded,
            AuthErrorKind::Io => SessionErrorKind::ConnectionLost,
        };
        Self::new(kind, error.message)
    }
}

fn io_error(error: io::Error, during: &str) -> SessionError {
    match error.kind() {
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut => SessionError::new(
            SessionErrorKind::TimedOut,
            format!("The VNC server stopped answering {during}."),
        ),
        io::ErrorKind::InvalidData => SessionError::protocol(error.to_string()),
        _ => SessionError::new(
            SessionErrorKind::ConnectionLost,
            format!("The connection closed {during}."),
        ),
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum SessionEvent {
    Connecting,
    Negotiated {
        rfb_version: String,
        offered: Vec<u8>,
        security: SecurityKind,
    },
    /// The encrypted handshake worked and the server asked for credentials.
    /// In a check, the session ends here without sending any.
    CredentialsRequested {
        username_needed: bool,
        server_key_bits: u32,
        server_key_sha256: String,
    },
    Connected {
        width: u16,
        height: u16,
        name: String,
        security: SecurityKind,
    },
    Resized {
        width: u16,
        height: u16,
    },
    Bell,
    /// The last event. `error` is absent when Mooring ended the session.
    Closed {
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<SessionError>,
    },
}

/// Running totals for the viewer's status line.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct SessionStats {
    /// Framebuffer updates received.
    pub updates: u64,
    pub rectangles: u64,
    /// Bytes received from the server, encryption included.
    pub bytes: u64,
}

/// The result of [`Session::copy_changes`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Copied {
    /// Not connected yet, or closed.
    NotReady,
    Unchanged,
    Region(Rect),
    /// The desktop is now this size; reallocate and copy again.
    SizeChanged {
        width: u16,
        height: u16,
    },
}

enum Input {
    Key { down: bool, keysym: u32 },
    Pointer { buttons: u8, x: u16, y: u16 },
}

#[derive(Default)]
struct InputState {
    queue: VecDeque<Input>,
    held: HeldKeys,
    buttons: u8,
    position: (u16, u16),
    scroll: (f64, f64),
    closed: bool,
}

impl InputState {
    fn push(&mut self, input: Input) {
        if let (Input::Pointer { buttons, .. }, Some(Input::Pointer { buttons: last, .. })) =
            (&input, self.queue.back())
            && buttons == last
        {
            self.queue.pop_back();
        }
        if self.queue.len() >= MAX_QUEUED_INPUT {
            // Keep the session usable: drop what is queued, and release every
            // held key and button so nothing stays pressed remotely.
            self.queue.clear();
            for keysym in self.held.release_all() {
                self.queue.push_back(Input::Key {
                    down: false,
                    keysym,
                });
            }
            self.buttons = 0;
            let (x, y) = self.position;
            self.queue.push_back(Input::Pointer { buttons: 0, x, y });
            return;
        }
        self.queue.push_back(input);
    }

    fn release_all(&mut self) {
        for keysym in self.held.release_all() {
            self.push(Input::Key {
                down: false,
                keysym,
            });
        }
        if self.buttons != 0 {
            self.buttons = 0;
            let (x, y) = self.position;
            self.push(Input::Pointer { buttons: 0, x, y });
        }
    }
}

struct Shared {
    framebuffer: Mutex<Option<Framebuffer>>,
    events: Mutex<VecDeque<SessionEvent>>,
    input: Mutex<InputState>,
    input_ready: Condvar,
    writer: Mutex<Option<RfbWriter>>,
    socket: Mutex<Option<TcpStream>>,
    stop: AtomicBool,
    updates: AtomicU64,
    rectangles: AtomicU64,
    bytes: AtomicU64,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Shared {
    fn event(&self, event: SessionEvent) {
        let mut events = lock(&self.events);
        if events.len() >= MAX_EVENTS {
            // Never drop the final event; drop the oldest other one.
            if let Some(index) = events
                .iter()
                .position(|e| !matches!(e, SessionEvent::Closed { .. }))
            {
                events.remove(index);
            }
        }
        events.push_back(event);
    }

    fn send(&self, data: &[u8]) -> io::Result<()> {
        match lock(&self.writer).as_mut() {
            Some(writer) => writer.send(data),
            None => Err(io::ErrorKind::NotConnected.into()),
        }
    }

    fn shutdown(&self) {
        if let Some(socket) = lock(&self.socket).as_ref() {
            let _ = socket.shutdown(Shutdown::Both);
        }
    }
}

pub struct Session {
    shared: Arc<Shared>,
    worker: Option<JoinHandle<()>>,
}

impl Session {
    /// Start connecting. `credentials` are used for this one attempt and
    /// dropped (wiped) as soon as they have been sent.
    pub fn start(config: SessionConfig, credentials: Option<Credentials>) -> Session {
        let shared = Arc::new(Shared {
            framebuffer: Mutex::new(None),
            events: Mutex::new(VecDeque::new()),
            input: Mutex::new(InputState::default()),
            input_ready: Condvar::new(),
            writer: Mutex::new(None),
            socket: Mutex::new(None),
            stop: AtomicBool::new(false),
            updates: AtomicU64::new(0),
            rectangles: AtomicU64::new(0),
            bytes: AtomicU64::new(0),
        });
        let worker_shared = Arc::clone(&shared);
        let worker = thread::Builder::new()
            .name("mooring-vnc".into())
            .spawn(move || {
                let error = run(&worker_shared, &config, credentials).err();
                let error = if worker_shared.stop.load(Ordering::SeqCst) {
                    None
                } else {
                    error
                };
                worker_shared.shutdown();
                *lock(&worker_shared.framebuffer) = None;
                worker_shared.event(SessionEvent::Closed { error });
            })
            .ok();
        if worker.is_none() {
            shared.event(SessionEvent::Closed {
                error: Some(SessionError::new(
                    SessionErrorKind::ConnectFailed,
                    "Could not start the viewer thread.",
                )),
            });
        }
        Session { shared, worker }
    }

    pub fn stats(&self) -> SessionStats {
        SessionStats {
            updates: self.shared.updates.load(Ordering::Relaxed),
            rectangles: self.shared.rectangles.load(Ordering::Relaxed),
            bytes: self.shared.bytes.load(Ordering::Relaxed),
        }
    }

    pub fn poll_event(&self) -> Option<SessionEvent> {
        lock(&self.shared.events).pop_front()
    }

    /// The desktop size and its layout number, once connected.
    pub fn size(&self) -> Option<(u16, u16, u64)> {
        lock(&self.shared.framebuffer)
            .as_ref()
            .map(|fb| (fb.width(), fb.height(), fb.layout()))
    }

    /// Copy what changed into the viewer's BGRX image.
    pub fn copy_changes(
        &self,
        destination: &mut [u8],
        stride: usize,
        width: u16,
        height: u16,
    ) -> Copied {
        let mut framebuffer = lock(&self.shared.framebuffer);
        let Some(framebuffer) = framebuffer.as_mut() else {
            return Copied::NotReady;
        };
        if framebuffer.dirty().is_empty()
            && framebuffer.width() == width
            && framebuffer.height() == height
        {
            return Copied::Unchanged;
        }
        match framebuffer.copy_changes(destination, stride, width, height) {
            Some(rect) => Copied::Region(rect),
            None => Copied::SizeChanged {
                width: framebuffer.width(),
                height: framebuffer.height(),
            },
        }
    }

    fn with_input(&self, apply: impl FnOnce(&mut InputState)) {
        let mut input = lock(&self.shared.input);
        if input.closed {
            return;
        }
        apply(&mut input);
        drop(input);
        self.shared.input_ready.notify_one();
    }

    /// A Mac key event: its virtual key code, the characters it produces
    /// without modifiers other than Shift, and whether it went down.
    pub fn key(&self, code: u16, characters: &str, down: bool) {
        self.with_input(|input| {
            if let Some((down, keysym)) = input.held.event(code, characters, down) {
                input.push(Input::Key { down, keysym });
            }
        });
    }

    /// Pointer position in desktop pixels (clamped) and buttons 1-3 as bits
    /// 0-2 (left, middle, right).
    pub fn pointer(&self, x: f64, y: f64, buttons: u8) {
        let (width, height) = self.size().map(|(w, h, _)| (w, h)).unwrap_or((1, 1));
        let clamp =
            |value: f64, max: u16| value.clamp(0.0, f64::from(max.saturating_sub(1))) as u16;
        let (x, y) = (clamp(x, width), clamp(y, height));
        self.with_input(|input| {
            input.position = (x, y);
            input.buttons = buttons & 0b111;
            input.push(Input::Pointer {
                buttons: input.buttons,
                x,
                y,
            });
        });
    }

    /// Scroll by `dx`, `dy` lines (positive: right and down). Fractions are
    /// kept until they add up to a whole click, as buttons 4 to 7.
    pub fn scroll(&self, dx: f64, dy: f64) {
        self.with_input(|input| {
            input.scroll.0 = (input.scroll.0 + dx).clamp(-50.0, 50.0);
            input.scroll.1 = (input.scroll.1 + dy).clamp(-50.0, 50.0);
            let (x, y) = input.position;
            let base = input.buttons;
            let clicks = |amount: &mut f64, positive: u8, negative: u8| {
                let mut out = Vec::new();
                while *amount >= 1.0 {
                    *amount -= 1.0;
                    out.push(positive);
                }
                while *amount <= -1.0 {
                    *amount += 1.0;
                    out.push(negative);
                }
                out
            };
            let mut buttons = clicks(&mut input.scroll.1, 1 << 4, 1 << 3);
            buttons.extend(clicks(&mut input.scroll.0, 1 << 6, 1 << 5));
            for button in buttons {
                input.queue.push_back(Input::Pointer {
                    buttons: base | button,
                    x,
                    y,
                });
                input.queue.push_back(Input::Pointer {
                    buttons: base,
                    x,
                    y,
                });
            }
            while input.queue.len() > MAX_QUEUED_INPUT {
                input.queue.pop_front();
            }
        });
    }

    /// Release every held key and button, for example when the window loses
    /// focus.
    pub fn release_all(&self) {
        self.with_input(InputState::release_all);
    }

    /// End the session: release held input, then close. Returns promptly.
    pub fn stop(&self) {
        if self.shared.stop.swap(true, Ordering::SeqCst) {
            return;
        }
        self.with_input(InputState::release_all);
        // Give the input thread a moment to send the releases.
        let deadline = Instant::now() + Duration::from_millis(300);
        while Instant::now() < deadline && !lock(&self.shared.input).queue.is_empty() {
            thread::sleep(Duration::from_millis(5));
        }
        lock(&self.shared.input).closed = true;
        self.shared.input_ready.notify_all();
        self.shared.shutdown();
    }
}

impl Session {
    /// Stop, then wait for the session thread. It may take up to the connect
    /// timeout if the session is still connecting.
    pub fn join(mut self) {
        self.stop();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Drop for Session {
    /// Stops without waiting for the thread, so the app never blocks on a
    /// slow network. The thread ends on its own once its socket is closed.
    fn drop(&mut self) {
        self.stop();
    }
}

fn connect(config: &SessionConfig) -> Result<TcpStream, SessionError> {
    let addresses: Vec<SocketAddr> = (config.host.as_str(), config.port)
        .to_socket_addrs()
        .map_err(|error| {
            SessionError::new(
                SessionErrorKind::ConnectFailed,
                format!("Could not resolve {}: {error}", config.host),
            )
        })?
        .collect();
    let mut last = None;
    for address in addresses {
        match TcpStream::connect_timeout(&address, config.connect_timeout) {
            Ok(stream) => return Ok(stream),
            Err(error) => last = Some(error),
        }
    }
    Err(SessionError::new(
        SessionErrorKind::ConnectFailed,
        format!(
            "Could not connect to {}:{}: {}",
            config.host,
            config.port,
            last.map_or_else(|| "no address".to_string(), |e| e.to_string())
        ),
    ))
}

fn run(
    shared: &Arc<Shared>,
    config: &SessionConfig,
    credentials: Option<Credentials>,
) -> Result<(), SessionError> {
    shared.event(SessionEvent::Connecting);
    // The client key takes a moment to generate; start it now.
    let bits = config.client_key_bits.clamp(1024, 4096);
    let keygen = thread::Builder::new()
        .name("mooring-vnc-key".into())
        .spawn(move || {
            if bits == auth::CLIENT_KEY_BITS {
                client_key()
            } else {
                RsaPrivateKey::new(&mut rand_core::OsRng, bits).map_err(|e| AuthError {
                    kind: AuthErrorKind::HandshakeFailed,
                    message: e.to_string(),
                })
            }
        })
        .map_err(|_| {
            SessionError::new(
                SessionErrorKind::ConnectFailed,
                "Could not start key generation.",
            )
        })?;
    let stream = connect(config)?;
    let _ = stream.set_nodelay(true);
    let _ = stream.set_read_timeout(Some(HANDSHAKE_TIMEOUT));
    let _ = stream.set_write_timeout(Some(WRITE_TIMEOUT));
    let clone = |s: &TcpStream| {
        s.try_clone()
            .map_err(|e| SessionError::new(SessionErrorKind::ConnectFailed, e.to_string()))
    };
    *lock(&shared.socket) = Some(clone(&stream)?);
    if shared.stop.load(Ordering::SeqCst) {
        return Ok(());
    }
    let mut reader = RfbReader::new(Box::new(clone(&stream)?));
    let mut writer = RfbWriter::new(Box::new(clone(&stream)?));

    let Negotiated {
        rfb_version,
        offered,
        security,
        minor,
    } = auth::negotiate(&mut reader, &mut writer)?;
    shared.event(SessionEvent::Negotiated {
        rfb_version,
        offered,
        security,
    });
    match security {
        SecurityKind::None => {
            if config.check_only {
                return Ok(());
            }
            if minor >= 8 {
                read_security_result(&mut reader, minor)?;
            }
        }
        SecurityKind::RsaAes128 | SecurityKind::RsaAes256 => {
            let key = keygen
                .join()
                .map_err(|_| SessionError::protocol("Key generation failed."))??;
            let ra2 = ra2_handshake(security, &mut reader, &mut writer, &key)?;
            shared.event(SessionEvent::CredentialsRequested {
                username_needed: ra2.credential_subtype == 1,
                server_key_bits: ra2.server_key_bits,
                server_key_sha256: ra2.server_key_sha256,
            });
            if config.check_only {
                return Ok(());
            }
            let Some(credentials) = credentials else {
                return Err(SessionError::new(
                    SessionErrorKind::CredentialsNeeded,
                    "The VNC server needs a username and password.",
                ));
            };
            send_credentials(&mut writer, ra2.credential_subtype, &credentials)?;
            drop(credentials);
            read_security_result(&mut reader, minor)?;
        }
    }

    // ClientInit: shared, so other viewers stay connected.
    writer
        .send(&[1])
        .map_err(|e| io_error(e, "after sign-in"))?;
    let width = reader.u16().map_err(|e| io_error(e, "after sign-in"))?;
    let height = reader.u16().map_err(|e| io_error(e, "after sign-in"))?;
    let mut format = [0_u8; 16];
    reader
        .read_exact(&mut format)
        .map_err(|e| io_error(e, "after sign-in"))?;
    let name_length = reader.u32().map_err(|e| io_error(e, "after sign-in"))?;
    let name = reader
        .bytes(name_length, proto::MAX_NAME_BYTES)
        .map_err(|e| io_error(e, "after sign-in"))?;
    let name: String = String::from_utf8_lossy(&name)
        .chars()
        .filter(|c| !c.is_control())
        .take(200)
        .collect();
    check_size(width, height)?;
    *lock(&shared.framebuffer) = Some(Framebuffer::new(width, height));
    writer
        .send(&proto::set_pixel_format(&PixelFormat::BGRX))
        .and_then(|()| writer.send(&proto::set_encodings(&proto::ENCODINGS)))
        .and_then(|()| writer.send(&proto::update_request(false, 0, 0, width, height)))
        .map_err(|e| io_error(e, "after sign-in"))?;
    *lock(&shared.writer) = Some(writer);
    // The desktop can be idle for a long time; only writes keep a timeout.
    let _ = stream.set_read_timeout(None);
    shared.event(SessionEvent::Connected {
        width,
        height,
        name,
        security,
    });

    let input_shared = Arc::clone(shared);
    let input = thread::Builder::new()
        .name("mooring-vnc-input".into())
        .spawn(move || send_input(&input_shared))
        .map_err(|_| SessionError::protocol("Could not start the input thread."))?;
    let result = receive(shared, &mut reader);
    lock(&shared.input).closed = true;
    shared.input_ready.notify_all();
    shared.shutdown();
    let _ = input.join();
    result
}

fn check_size(width: u16, height: u16) -> Result<(), SessionError> {
    if width == 0
        || height == 0
        || width > proto::MAX_DIMENSION
        || height > proto::MAX_DIMENSION
        || usize::from(width) * usize::from(height) > MAX_PIXELS
    {
        return Err(SessionError::protocol(format!(
            "The remote desktop is {width}x{height}, which Mooring does not support."
        )));
    }
    Ok(())
}

fn send_input(shared: &Shared) {
    loop {
        let batch: Vec<Input> = {
            let mut input = lock(&shared.input);
            while input.queue.is_empty() && !input.closed {
                input = shared
                    .input_ready
                    .wait(input)
                    .unwrap_or_else(PoisonError::into_inner);
            }
            if input.queue.is_empty() && input.closed {
                return;
            }
            input.queue.drain(..).collect()
        };
        let mut bytes = Vec::with_capacity(batch.len() * 8);
        for item in batch {
            match item {
                Input::Key { down, keysym } => {
                    bytes.extend_from_slice(&proto::key_event(down, keysym))
                }
                Input::Pointer { buttons, x, y } => {
                    bytes.extend_from_slice(&proto::pointer_event(buttons, x, y))
                }
            }
        }
        if shared.send(&bytes).is_err() {
            return;
        }
    }
}

fn receive(shared: &Shared, reader: &mut RfbReader) -> Result<(), SessionError> {
    let mut zrle = ZrleDecoder::new();
    let mut row = Vec::new();
    let lost = |e: io::Error| io_error(e, "during the session");
    loop {
        let message = match reader.u8() {
            Ok(message) => message,
            Err(_) if shared.stop.load(Ordering::SeqCst) => return Ok(()),
            Err(error) => return Err(lost(error)),
        };
        match message {
            0 => {
                let mut header = [0_u8; 3];
                reader.read_exact(&mut header).map_err(lost)?;
                let count = u16::from_be_bytes([header[1], header[2]]);
                let mut resized = false;
                for _ in 0..count {
                    let x = reader.u16().map_err(lost)?;
                    let y = reader.u16().map_err(lost)?;
                    let width = reader.u16().map_err(lost)?;
                    let height = reader.u16().map_err(lost)?;
                    let kind = reader.i32().map_err(lost)?;
                    let rect = Rect::new(x, y, width, height);
                    match kind {
                        encoding::LAST_RECT => break,
                        encoding::DESKTOP_SIZE => {
                            resize(shared, width, height)?;
                            resized = true;
                        }
                        encoding::EXTENDED_DESKTOP_SIZE => {
                            let screens = reader.u8().map_err(lost)?;
                            reader.skip(3 + u64::from(screens) * 16).map_err(lost)?;
                            // y is the status: 0 means the layout changed.
                            if y == 0 {
                                resize(shared, width, height)?;
                                resized = true;
                            }
                        }
                        _ => {
                            let within = lock(&shared.framebuffer)
                                .as_ref()
                                .is_some_and(|fb| fb.contains(&rect));
                            if !within {
                                return Err(SessionError::protocol(
                                    "The server sent a rectangle outside the desktop.",
                                ));
                            }
                            decode(shared, reader, &mut zrle, &mut row, kind, &rect)?;
                        }
                    }
                }
                shared.updates.fetch_add(1, Ordering::Relaxed);
                shared
                    .rectangles
                    .fetch_add(u64::from(count), Ordering::Relaxed);
                shared.bytes.store(reader.wire_bytes(), Ordering::Relaxed);
                let size = lock(&shared.framebuffer)
                    .as_ref()
                    .map(|fb| (fb.width(), fb.height()));
                if let Some((width, height)) = size {
                    shared
                        .send(&proto::update_request(!resized, 0, 0, width, height))
                        .map_err(lost)?;
                }
            }
            1 => {
                let mut header = [0_u8; 5];
                reader.read_exact(&mut header).map_err(lost)?;
                let count = u16::from_be_bytes([header[3], header[4]]);
                reader.skip(u64::from(count) * 6).map_err(lost)?;
            }
            2 => shared.event(SessionEvent::Bell),
            3 => {
                let mut padding = [0_u8; 3];
                reader.read_exact(&mut padding).map_err(lost)?;
                // Extended clipboard sends a negative length; skip either way.
                let length = reader.i32().map_err(lost)?;
                reader
                    .skip(u64::from(length.unsigned_abs()))
                    .map_err(lost)?;
            }
            other => {
                return Err(SessionError::protocol(format!(
                    "The server sent message type {other}, which Mooring does not support."
                )));
            }
        }
    }
}

fn resize(shared: &Shared, width: u16, height: u16) -> Result<(), SessionError> {
    check_size(width, height)?;
    if let Some(framebuffer) = lock(&shared.framebuffer).as_mut() {
        if (framebuffer.width(), framebuffer.height()) == (width, height) {
            return Ok(());
        }
        framebuffer.resize(width, height);
    }
    shared.event(SessionEvent::Resized { width, height });
    Ok(())
}

fn decode(
    shared: &Shared,
    reader: &mut RfbReader,
    zrle: &mut ZrleDecoder,
    row: &mut Vec<u8>,
    kind: i32,
    rect: &Rect,
) -> Result<(), SessionError> {
    let lost = |e: io::Error| io_error(e, "during the session");
    match kind {
        encoding::RAW => {
            // Row by row, so a large rectangle needs no second full copy and
            // the viewer can still copy frames meanwhile.
            row.resize(usize::from(rect.width) * BYTES_PER_PIXEL, 0);
            for line in 0..rect.height {
                reader.read_exact(row).map_err(lost)?;
                let line_rect = Rect::new(rect.x, rect.y + line, rect.width, 1);
                if let Some(fb) = lock(&shared.framebuffer).as_mut() {
                    fb.put(&line_rect, row);
                }
            }
        }
        encoding::COPY_RECT => {
            let source_x = reader.u16().map_err(lost)?;
            let source_y = reader.u16().map_err(lost)?;
            let mut framebuffer = lock(&shared.framebuffer);
            let Some(fb) = framebuffer.as_mut() else {
                return Ok(());
            };
            if !fb.contains(&Rect::new(source_x, source_y, rect.width, rect.height)) {
                return Err(SessionError::protocol(
                    "The server asked to copy from outside the desktop.",
                ));
            }
            fb.copy_within(source_x, source_y, rect);
        }
        encoding::ZRLE => {
            let length = reader.u32().map_err(lost)?;
            let compressed = reader.bytes(length, MAX_COMPRESSED_BYTES).map_err(lost)?;
            let mut framebuffer = lock(&shared.framebuffer);
            if let Some(fb) = framebuffer.as_mut() {
                zrle.decode(&compressed, rect, fb)
                    .map_err(SessionError::protocol)?;
            }
        }
        other => {
            return Err(SessionError::protocol(format!(
                "The server sent encoding {other}, which Mooring did not ask for."
            )));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake_server::{FakeServer, Record, Script, update};
    use crate::keysym::x;
    use crate::proto::security;
    use crate::zrle::tests::ZrleEncoder;

    fn config(server: &FakeServer) -> SessionConfig {
        let mut config = SessionConfig::new("127.0.0.1", server.port);
        config.client_key_bits = 1024;
        config
    }

    fn credentials(password: &[u8]) -> Option<Credentials> {
        Some(Credentials::new("alex", password.to_vec()).unwrap())
    }

    /// Collect events until one matches `stop`, within ten seconds.
    fn events_until(session: &Session, stop: impl Fn(&SessionEvent) -> bool) -> Vec<SessionEvent> {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut seen = Vec::new();
        while Instant::now() < deadline {
            while let Some(event) = session.poll_event() {
                let done = stop(&event);
                seen.push(event);
                if done {
                    return seen;
                }
            }
            thread::sleep(Duration::from_millis(5));
        }
        panic!("timed out; events so far: {seen:?}");
    }

    fn closed(event: &SessionEvent) -> bool {
        matches!(event, SessionEvent::Closed { .. })
    }

    fn connected(event: &SessionEvent) -> bool {
        matches!(
            event,
            SessionEvent::Connected { .. } | SessionEvent::Closed { .. }
        )
    }

    fn close_error(events: &[SessionEvent]) -> Option<SessionError> {
        match events.last() {
            Some(SessionEvent::Closed { error }) => error.clone(),
            other => panic!("not closed: {other:?}"),
        }
    }

    #[test]
    fn signs_in_with_rsa_aes_256_and_sets_up_the_session() {
        let server = FakeServer::start(Script::default());
        let session = Session::start(config(&server), credentials(b"correct horse"));
        let events = events_until(&session, connected);
        assert!(matches!(events[0], SessionEvent::Connecting));
        assert!(events.iter().any(|e| matches!(e, SessionEvent::Negotiated { security: SecurityKind::RsaAes256, offered, .. } if offered == &[129, 5, 30])));
        assert!(events.iter().any(|e| matches!(
            e,
            SessionEvent::CredentialsRequested {
                username_needed: true,
                server_key_bits: 1024,
                ..
            }
        )));
        assert_eq!(
            events.last(),
            Some(&SessionEvent::Connected {
                width: 64,
                height: 32,
                name: "alex's Omarchy desktop".into(),
                security: SecurityKind::RsaAes256
            })
        );
        let record = server.wait_for(|r| !r.update_requests.is_empty());
        assert_eq!(record.chosen, Some(security::RA2_256));
        assert_eq!(record.username.as_deref(), Some("alex"));
        assert_eq!(record.password_matched, Some(true));
        assert_eq!(record.shared_flag, Some(1));
        assert_eq!(record.pixel_format, Some(PixelFormat::BGRX.encode()));
        assert_eq!(record.encodings, proto::ENCODINGS);
        assert_eq!(
            record.update_requests[0],
            proto::update_request(false, 0, 0, 64, 32)
        );
        assert_eq!(session.size().map(|(w, h, _)| (w, h)), Some((64, 32)));
        drop(session);
        assert!(server.wait_for(|r| r.closed_by_client).closed_by_client);
        server.finish().unwrap();
    }

    #[test]
    fn rsa_aes_128_works_too() {
        let server = FakeServer::start(Script {
            offered: vec![security::RA2],
            ..Script::default()
        });
        let session = Session::start(config(&server), credentials(b"correct horse"));
        let events = events_until(&session, connected);
        assert!(matches!(
            events.last(),
            Some(SessionEvent::Connected {
                security: SecurityKind::RsaAes128,
                ..
            })
        ));
        assert_eq!(server.record().chosen, Some(security::RA2));
    }

    #[test]
    fn a_wrong_password_is_tried_once_and_reported() {
        let server = FakeServer::start(Script::default());
        let session = Session::start(config(&server), credentials(b"wrong"));
        let events = events_until(&session, closed);
        let error = close_error(&events).unwrap();
        assert_eq!(error.kind, SessionErrorKind::SignInRejected);
        assert!(
            error.message.contains("Authentication failed"),
            "{}",
            error.message
        );
        assert_eq!(server.record().password_matched, Some(false));
        // The fake server accepts one connection: a retry would fail to connect,
        // and the session reports one rejection, not a retry.
        server.finish().unwrap();
        assert_eq!(session.size(), None);
    }

    #[test]
    fn a_check_stops_before_sending_any_credentials() {
        let server = FakeServer::start(Script::default());
        let mut config = config(&server);
        config.check_only = true;
        let session = Session::start(config, None);
        let events = events_until(&session, closed);
        assert!(
            events
                .iter()
                .any(|e| matches!(e, SessionEvent::CredentialsRequested { .. }))
        );
        assert_eq!(close_error(&events), None);
        server.finish().unwrap_err(); // the client hung up while asked for credentials
        assert_eq!(server_username_after_check(), None);
    }

    fn server_username_after_check() -> Option<String> {
        // Run the same check against a fresh server and read its record.
        let server = FakeServer::start(Script::default());
        let mut config = config(&server);
        config.check_only = true;
        let session = Session::start(config, None);
        events_until(&session, closed);
        let _ = server.wait_for(|r| r.chosen.is_some());
        thread::sleep(Duration::from_millis(50));
        server.record().username
    }

    #[test]
    fn a_tampered_handshake_never_reaches_credentials() {
        let server = FakeServer::start(Script {
            bad_server_hash: true,
            ..Script::default()
        });
        let session = Session::start(config(&server), credentials(b"correct horse"));
        let events = events_until(&session, closed);
        assert_eq!(
            close_error(&events).unwrap().kind,
            SessionErrorKind::HandshakeFailed
        );
        thread::sleep(Duration::from_millis(50));
        assert_eq!(server.record().username, None);
    }

    #[test]
    fn apple_dh_alone_is_refused_without_selecting_it() {
        let server = FakeServer::start(Script {
            offered: vec![security::APPLE_DH, security::VNC_PASSWORD],
            ..Script::default()
        });
        let session = Session::start(config(&server), credentials(b"correct horse"));
        let events = events_until(&session, closed);
        let error = close_error(&events).unwrap();
        assert_eq!(error.kind, SessionErrorKind::UnsupportedSecurity);
        assert!(error.message.contains("30, 2"), "{}", error.message);
        thread::sleep(Duration::from_millis(50));
        assert_eq!(
            server.record().chosen,
            None,
            "Mooring must not select type 30 or 2"
        );
    }

    #[test]
    fn a_server_without_sign_in_needs_no_credentials() {
        let server = FakeServer::start(Script {
            offered: vec![security::NONE],
            ..Script::default()
        });
        let session = Session::start(config(&server), None);
        let events = events_until(&session, connected);
        assert!(matches!(
            events.last(),
            Some(SessionEvent::Connected {
                security: SecurityKind::None,
                ..
            })
        ));
        assert_eq!(server.record().username, None);
    }

    const BLUE: [u8; 4] = [200, 0, 0, 0xff];

    #[test]
    fn decodes_raw_copy_rect_zrle_and_resizes() {
        let mut zrle = ZrleEncoder::new();
        let solid_green = zrle.rect(&[1, 0, 200, 0]);
        let mut zrle_body = (solid_green.len() as u32).to_be_bytes().to_vec();
        zrle_body.extend_from_slice(&solid_green);
        // The server's padding byte is 0; Mooring stores it as opaque.
        let raw: Vec<u8> = [200, 0, 0, 0].repeat(4);
        let server = FakeServer::start(Script {
            updates: vec![
                update(&[
                    (0, 0, 2, 2, encoding::RAW, raw),
                    (10, 10, 2, 2, encoding::COPY_RECT, vec![0, 0, 0, 0]),
                    (20, 0, 4, 4, encoding::ZRLE, zrle_body),
                ]),
                update(&[(0, 0, 80, 40, encoding::DESKTOP_SIZE, Vec::new())]),
            ],
            ..Script::default()
        });
        let session = Session::start(config(&server), credentials(b"correct horse"));
        events_until(&session, connected);
        server.wait_for(|r| r.update_requests.len() >= 2);
        let mut image = vec![0_u8; 64 * 32 * 4];
        let at = |image: &[u8], x: usize, y: usize| -> [u8; 4] {
            let offset = (y * 64 + x) * 4;
            image[offset..offset + 4].try_into().unwrap()
        };
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let copied = session.copy_changes(&mut image, 64 * 4, 64, 32);
            if matches!(
                copied,
                Copied::SizeChanged {
                    width: 80,
                    height: 40
                }
            ) {
                break;
            }
            assert!(Instant::now() < deadline, "no resize: {copied:?}");
            if at(&image, 21, 1) == [0, 200, 0, 0xff] {
                assert_eq!(at(&image, 1, 1), BLUE);
                assert_eq!(at(&image, 11, 11), BLUE, "CopyRect");
                assert_eq!(at(&image, 5, 5), [0, 0, 0, 0xff]);
            }
            thread::sleep(Duration::from_millis(5));
        }
        let events = events_until(&session, |e| matches!(e, SessionEvent::Resized { .. }));
        assert_eq!(
            events.last(),
            Some(&SessionEvent::Resized {
                width: 80,
                height: 40
            })
        );
        // After a resize, Mooring asks for the whole new desktop.
        let record = server.wait_for(|r| r.update_requests.len() >= 3);
        assert_eq!(
            record.update_requests[1],
            proto::update_request(true, 0, 0, 64, 32)
        );
        assert_eq!(
            record.update_requests[2],
            proto::update_request(false, 0, 0, 80, 40)
        );
        let stats = session.stats();
        assert!(stats.updates >= 2 && stats.rectangles >= 4, "{stats:?}");
        // The handshake, ServerInit and both updates (a 2x2 raw rectangle alone
        // is 16 bytes plus a 12-byte header) all count.
        assert!(stats.bytes > 200, "{stats:?}");
        let mut bigger = vec![0_u8; 80 * 40 * 4];
        assert_eq!(
            session.copy_changes(&mut bigger, 80 * 4, 80, 40),
            Copied::Region(Rect::new(0, 0, 80, 40))
        );
    }

    #[test]
    fn a_rectangle_outside_the_desktop_ends_the_session() {
        let server = FakeServer::start(Script {
            updates: vec![update(&[(60, 30, 10, 10, encoding::RAW, vec![0; 400])])],
            ..Script::default()
        });
        let session = Session::start(config(&server), credentials(b"correct horse"));
        let events = events_until(&session, closed);
        assert_eq!(
            close_error(&events).unwrap().kind,
            SessionErrorKind::ProtocolError
        );
    }

    #[test]
    fn an_impossible_desktop_size_is_refused() {
        let server = FakeServer::start(Script {
            width: 16_000,
            height: 16_000,
            ..Script::default()
        });
        let session = Session::start(config(&server), credentials(b"correct horse"));
        let events = events_until(&session, closed);
        let error = close_error(&events).unwrap();
        assert_eq!(error.kind, SessionErrorKind::ProtocolError);
        assert!(error.message.contains("16000x16000"));
    }

    #[test]
    fn input_is_sent_and_released_when_the_session_stops() {
        let server = FakeServer::start(Script::default());
        let session = Session::start(config(&server), credentials(b"correct horse"));
        events_until(&session, connected);
        session.key(0x38, "", true); // Shift
        session.key(0x00, "A", true);
        session.key(0x00, "A", false);
        session.key(0x37, "", true); // Command, held
        for x in 0..50 {
            session.pointer(f64::from(x), 5.0, 0);
        }
        session.pointer(10.0, 5.0, 1); // left button down, held
        session.scroll(0.0, 1.5); // one click down; half a click kept
        session.pointer(1e9, -3.0, 1); // clamped to the desktop
        let record = server.wait_for(|r| r.pointer.iter().any(|p| p.1 == 63));
        assert_eq!(
            &record.keys[..4],
            [
                (true, x::SHIFT_L),
                (true, 0x41),
                (false, 0x41),
                (true, x::SUPER_L)
            ]
        );
        // 50 moves with the same buttons were merged, not all sent.
        assert!(record.pointer.len() < 50, "{:?}", record.pointer.len());
        assert!(
            record.pointer.contains(&(1 | 1 << 4, 10, 5)),
            "{:?}",
            record.pointer
        );
        assert!(record.pointer.contains(&(1, 10, 5)));
        assert_eq!(record.pointer.last(), Some(&(1, 63, 0)));
        drop(session);
        let record: Record = server.wait_for(|r| r.closed_by_client);
        // Shift, Command and the button were all released before closing.
        let mut released = record.keys[4..].to_vec();
        released.sort();
        assert_eq!(
            released,
            [(false, x::SHIFT_L), (false, x::SUPER_L)],
            "{:?}",
            record.keys
        );
        assert_eq!(record.pointer.last().map(|p| p.0), Some(0));
    }
}
