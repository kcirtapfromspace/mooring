//! Reach a VNC server through the system OpenSSH client.
//!
//! Mooring never asks for, stores or logs an SSH or VNC password. It runs
//! `/usr/bin/ssh` with the user's own `~/.ssh/config`, keys and agent, in batch
//! mode with password and keyboard-interactive sign-in turned off, so a missing
//! key fails in seconds instead of waiting on a prompt, and the remote PAM
//! stack is never asked to check a password.
//!
//! Mooring listens on 127.0.0.1 only. Each viewer connection to that listener
//! gets its own `ssh -W host:port` stdio forward, and the bytes are relayed
//! through bounded buffers. When the viewer leaves, that ssh is stopped and
//! reaped. Because ssh's only data path is a pipe from this process, an ssh
//! whose supervisor dies gets end-of-file and exits instead of lingering.
//! Arguments are always passed as an argv array, never through a shell.

mod desktop;
mod screen;

pub use desktop::{
    DESKTOP_PROBE_SCRIPT, DESKTOP_PROBE_TIMEOUT, DesktopEvent, desktop_probe_args, probe_desktop,
    watch_desktop,
};
pub use screen::{
    ScreenSize, VIRTUAL_SCREEN_READY_TIMEOUT, VIRTUAL_SCREEN_SCRIPT, VirtualScreen,
    start_virtual_screen, virtual_screen_args,
};

use crate::parse_greeting;
use mooring_core::tunnel::{
    Admission, CheckDecision, CloseReason, TunnelLifecycle, TunnelLimits, TunnelPhase,
};
use serde::Serialize;
use std::collections::VecDeque;
use std::ffi::OsString;
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::PathBuf;
use std::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// The system OpenSSH client. Never resolved through `PATH`.
pub const SYSTEM_SSH: &str = "/usr/bin/ssh";
/// The VNC endpoint as seen from the SSH host, when none is saved.
pub const DEFAULT_REMOTE_HOST: &str = "127.0.0.1";
pub const DEFAULT_REMOTE_PORT: u16 = 5900;

const MAX_TARGET_LENGTH: usize = 255;
const MAX_USER_LENGTH: usize = 64;
const STDERR_LINES: usize = 12;
const STDERR_LINE_BYTES: usize = 300;
const RELAY_BUFFER_BYTES: usize = 64 * 1024;
const MAX_REFUSAL_REASON_BYTES: usize = 512;
const TICK: Duration = Duration::from_millis(50);

/// Validate an SSH destination: a `~/.ssh/config` host alias, a hostname or
/// IP address, optionally prefixed with `user@`. Ports, options, URLs and
/// spaces are refused; put those in `~/.ssh/config`.
pub fn validate_ssh_target(target: &str) -> Result<String, String> {
    const INVALID: &str = "Enter an SSH host alias or user@host only, without spaces, options, a port or a URL. Put the port and other settings in ~/.ssh/config.";
    if target.is_empty() || target.len() > MAX_TARGET_LENGTH || !target.is_ascii() {
        return Err(INVALID.into());
    }
    let (user, host) = match target.split_once('@') {
        Some((user, host)) => (Some(user), host),
        None => (None, target),
    };
    if let Some(user) = user {
        let first = user.as_bytes().first().copied().unwrap_or(b'-');
        if user.len() > MAX_USER_LENGTH
            || !(first.is_ascii_alphanumeric() || first == b'_')
            || !user
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        {
            return Err(INVALID.into());
        }
    }
    if host.contains(':') {
        // Only a literal IPv6 address may contain a colon; never host:port.
        return host
            .parse::<Ipv6Addr>()
            .map(|_| target.to_owned())
            .map_err(|_| INVALID.into());
    }
    let first = host.as_bytes().first().copied().unwrap_or(b'-');
    if host.is_empty()
        || host.len() > 253
        || !first.is_ascii_alphanumeric()
        || host.contains("..")
        || !host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    {
        return Err(INVALID.into());
    }
    // Like validate_host: no abbreviated or octal IPv4 such as 127.1.
    if host.bytes().all(|b| b.is_ascii_digit() || b == b'.') && host.parse::<Ipv4Addr>().is_err() {
        return Err("Use a complete IPv4 address, for example 192.168.1.10.".into());
    }
    Ok(target.to_owned())
}

/// Where the VNC server is, as seen from the SSH host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SshRoute {
    pub target: String,
    pub remote_host: String,
    pub remote_port: u16,
}

impl SshRoute {
    pub fn new(target: &str, remote_host: &str, remote_port: u16) -> Result<Self, String> {
        let target = validate_ssh_target(target)?;
        let remote_host = crate::validate_host(remote_host)?;
        crate::validate_port(remote_port)?;
        Ok(Self {
            target,
            remote_host,
            remote_port,
        })
    }

    /// The `-W` argument. IPv6 is bracketed exactly once.
    pub fn remote_spec(&self) -> String {
        if self.remote_host.parse::<Ipv6Addr>().is_ok() {
            format!("[{}]:{}", self.remote_host, self.remote_port)
        } else {
            format!("{}:{}", self.remote_host, self.remote_port)
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SshOptions {
    /// Always [`SYSTEM_SSH`] in Mooring; tests substitute a fake program.
    pub program: PathBuf,
    /// An alternate config file, passed as `-F`. Used to test failures with an
    /// isolated configuration; by default ssh reads `~/.ssh/config`.
    pub config_file: Option<PathBuf>,
    pub connect_timeout_secs: u32,
}

impl Default for SshOptions {
    fn default() -> Self {
        Self {
            program: PathBuf::from(SYSTEM_SSH),
            config_file: None,
            connect_timeout_secs: 6,
        }
    }
}

/// The options Mooring always sets. Command-line `-o` values take precedence
/// over `~/.ssh/config`, so these cannot be weakened by a config file:
/// no prompts, no password or keyboard-interactive sign-in (so a remote PAM
/// lockout is never fed failed passwords), no extra forwards from the config,
/// no background control master that could outlive the session, and bounded
/// connect and keep-alive timeouts.
fn fixed_options(connect_timeout_secs: u32) -> [(&'static str, String); 15] {
    [
        ("BatchMode", "yes".into()),
        ("PasswordAuthentication", "no".into()),
        ("KbdInteractiveAuthentication", "no".into()),
        (
            "ConnectTimeout",
            connect_timeout_secs.clamp(1, 60).to_string(),
        ),
        ("ConnectionAttempts", "1".into()),
        ("ServerAliveInterval", "15".into()),
        ("ServerAliveCountMax", "3".into()),
        ("ExitOnForwardFailure", "yes".into()),
        ("ClearAllForwardings", "yes".into()),
        ("ControlMaster", "no".into()),
        ("ControlPersist", "no".into()),
        ("PermitLocalCommand", "no".into()),
        ("ForwardAgent", "no".into()),
        ("ForwardX11", "no".into()),
        ("LogLevel", "INFO".into()),
    ]
}

/// The options every Mooring ssh starts with: an optional `-F` and the fixed
/// `-o` settings.
fn base_args(options: &SshOptions) -> Vec<OsString> {
    let mut args: Vec<OsString> = Vec::with_capacity(40);
    if let Some(config) = &options.config_file {
        args.push("-F".into());
        args.push(config.clone().into_os_string());
    }
    for (key, value) in fixed_options(options.connect_timeout_secs) {
        args.push("-o".into());
        args.push(format!("{key}={value}").into());
    }
    args
}

/// The complete argv after the program name. The destination always follows
/// `--`, so even a value that slipped past validation cannot become an option.
pub fn ssh_forward_args(route: &SshRoute, options: &SshOptions) -> Vec<OsString> {
    let mut args = base_args(options);
    args.push("-W".into());
    args.push(route.remote_spec().into());
    args.push("--".into());
    args.push(route.target.clone().into());
    args
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SshFailureKind {
    InvalidRoute,
    SshUnavailable,
    HostNotFound,
    HostUnreachable,
    SshPortRefused,
    HostKeyUnknown,
    HostKeyChanged,
    AuthenticationFailed,
    RemotePortClosed,
    ForwardingDenied,
    ConnectionDropped,
    NotVnc,
    ServerRefused,
    TimedOut,
    SshConfig,
    Other,
}

/// A readable, credential-free description of why SSH or VNC setup failed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SshFailure {
    pub kind: SshFailureKind,
    pub message: String,
    /// Whether retrying soon could help (a dropped handshake, not a bad key).
    pub transient: bool,
    pub ssh_exit_code: Option<i32>,
    /// The last few lines ssh printed, reduced to printable ASCII.
    pub ssh_output: Vec<String>,
}

impl SshFailure {
    fn new(kind: SshFailureKind, message: String) -> Self {
        Self {
            kind,
            transient: kind == SshFailureKind::ConnectionDropped,
            message,
            ssh_exit_code: None,
            ssh_output: Vec::new(),
        }
    }

    fn with_output(mut self, status: Option<ExitStatus>, output: Vec<String>) -> Self {
        self.ssh_exit_code = status.and_then(|status| status.code());
        self.ssh_output = output;
        self
    }
}

/// Map what ssh printed to a failure a person can act on. The most specific
/// match wins: a forwarding failure also mentions "Connection refused".
pub fn classify_ssh_output(route: &SshRoute, lines: &[String]) -> Option<SshFailure> {
    use SshFailureKind as K;
    let text = lines.join("\n").to_ascii_lowercase();
    let target = &route.target;
    let remote = route.remote_spec();
    let has = |needle: &str| text.contains(needle);
    let (kind, message) = if has("open failed: administratively prohibited") {
        (
            K::ForwardingDenied,
            format!(
                "SSH signed in to {target}, but its server does not allow forwarding to {remote}. Check AllowTcpForwarding and PermitOpen in the remote sshd_config."
            ),
        )
    } else if has("open failed") || has("stdio forwarding failed") {
        (
            K::RemotePortClosed,
            format!(
                "SSH signed in to {target}, but nothing accepted a connection at {remote} there. Check that the VNC server is running and listening on that address and port."
            ),
        )
    } else if has("remote host identification has changed") {
        (
            K::HostKeyChanged,
            format!(
                "The host key for {target} has changed since it was saved in known_hosts. Mooring will not connect. Verify the host, then fix known_hosts in Terminal."
            ),
        )
    } else if has("host key verification failed") || has("no ed25519 host key is known") {
        (
            K::HostKeyUnknown,
            format!(
                "{target} is not in known_hosts yet. Run `ssh {target}` once in Terminal to verify and save its host key, then connect again."
            ),
        )
    } else if has("could not resolve hostname") {
        (
            K::HostNotFound,
            format!(
                "SSH could not find the host {target}. Check the name, or the Host entry in ~/.ssh/config."
            ),
        )
    } else if has("permission denied") || has("too many authentication failures") {
        (
            K::AuthenticationFailed,
            format!(
                "SSH sign-in to {target} failed: no key was accepted. Mooring uses only your SSH keys and agent and never asks for a password. Check that `ssh {target}` works in Terminal without a prompt."
            ),
        )
    } else if has("connection refused") {
        (
            K::SshPortRefused,
            format!("{target} refused the SSH connection. Check that SSH is enabled there."),
        )
    } else if has("timed out")
        || has("no route to host")
        || has("network is unreachable")
        || has("host is down")
        || has("not responding")
    {
        (
            K::HostUnreachable,
            format!(
                "{target} did not answer over SSH in time. Check that it is awake and on the network."
            ),
        )
    } else if has("connection closed by")
        || has("connection reset")
        || has("kex_exchange_identification")
        || has("broken pipe")
    {
        (
            K::ConnectionDropped,
            format!("{target} closed the SSH connection during setup."),
        )
    } else if has("bad configuration option")
        || has("unsupported option")
        || has("terminating, ")
        || has("bad owner or permissions")
    {
        (
            K::SshConfig,
            "ssh could not read its configuration. Run `ssh -G` with this host in Terminal to see the problem.".to_string(),
        )
    } else {
        return None;
    };
    Some(SshFailure::new(kind, message))
}

/// Printable ASCII only, so ssh output can't inject terminal or JSON controls.
fn sanitize_line(bytes: &[u8]) -> String {
    let mut line: String = bytes
        .iter()
        .take(STDERR_LINE_BYTES)
        .map(|&b| {
            if b == b'\t' {
                ' '
            } else if (0x20..0x7f).contains(&b) {
                b as char
            } else {
                '?'
            }
        })
        .collect();
    line.truncate(line.trim_end().len());
    line
}

/// Drains ssh's stderr so it never blocks, keeping only the last few lines.
struct StderrLog {
    lines: Arc<Mutex<VecDeque<String>>>,
    finished: mpsc::Receiver<()>,
}

impl StderrLog {
    fn start(mut stderr: ChildStderr) -> Self {
        let lines = Arc::new(Mutex::new(VecDeque::with_capacity(STDERR_LINES)));
        let (done, finished) = mpsc::sync_channel(1);
        let store = Arc::clone(&lines);
        let spawned = thread::Builder::new()
            .name("mooring-ssh-stderr".into())
            .spawn(move || {
                let mut chunk = [0_u8; 1024];
                let mut current = Vec::with_capacity(STDERR_LINE_BYTES);
                let push = |line: &mut Vec<u8>| {
                    let text = sanitize_line(line);
                    line.clear();
                    if text.is_empty() {
                        return;
                    }
                    let mut lines = lock(&store);
                    if lines.len() == STDERR_LINES {
                        lines.pop_front();
                    }
                    lines.push_back(text);
                };
                loop {
                    match stderr.read(&mut chunk) {
                        Ok(0) => break,
                        Ok(size) => {
                            for &byte in &chunk[..size] {
                                if byte == b'\n' || byte == b'\r' {
                                    push(&mut current);
                                } else if current.len() < STDERR_LINE_BYTES {
                                    current.push(byte);
                                }
                            }
                        }
                        Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                        Err(_) => break,
                    }
                }
                push(&mut current);
                let _ = done.send(());
            });
        if spawned.is_err() {
            lock(&lines).push_back("Mooring could not read ssh's messages.".into());
        }
        Self { lines, finished }
    }

    /// Wait briefly for ssh to finish writing, then return what it said.
    fn collect(&self, wait: Duration) -> Vec<String> {
        let _ = self.finished.recv_timeout(wait);
        lock(&self.lines).iter().cloned().collect()
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// One ssh child. It is signalled only before it has been reaped, so a
/// recycled process ID can never be hit.
struct SshProcess {
    state: Mutex<(Child, Option<ExitStatus>)>,
    stopped_by_mooring: AtomicBool,
}

impl SshProcess {
    fn status(&self) -> Option<ExitStatus> {
        let mut state = lock(&self.state);
        if state.1.is_none()
            && let Ok(Some(status)) = state.0.try_wait()
        {
            state.1 = Some(status);
        }
        state.1
    }

    fn signal(&self, signal: libc::c_int) {
        let state = lock(&self.state);
        if state.1.is_none() {
            self.stopped_by_mooring.store(true, Ordering::SeqCst);
            if let Ok(pid) = libc::pid_t::try_from(state.0.id()) {
                // ssh leads its own process group (see spawn_ssh), so this also
                // reaches a ProxyCommand child. The group ID cannot have been
                // reused: its leader is still unreaped.
                // SAFETY: kill(2) on the process group of a live child.
                unsafe { libc::kill(-pid, signal) };
            }
        }
    }

    fn wait_for(&self, limit: Duration) -> Option<ExitStatus> {
        let deadline = Instant::now() + limit;
        loop {
            if let Some(status) = self.status() {
                return Some(status);
            }
            if Instant::now() >= deadline {
                return None;
            }
            thread::sleep(Duration::from_millis(10));
        }
    }

    /// Let ssh exit on its own for `grace`, then SIGTERM, then SIGKILL. Always
    /// reaps the child before returning.
    fn finish(&self, grace: Duration) -> ExitStatus {
        if let Some(status) = self.wait_for(grace) {
            return status;
        }
        self.signal(libc::SIGTERM);
        if let Some(status) = self.wait_for(Duration::from_secs(1)) {
            return status;
        }
        self.signal(libc::SIGKILL);
        let mut state = lock(&self.state);
        if let Some(status) = state.1 {
            return status;
        }
        let status = state
            .0
            .wait()
            .unwrap_or_else(|_| ExitStatus::from_raw(libc::SIGKILL));
        state.1 = Some(status);
        status
    }

    fn pid(&self) -> u32 {
        lock(&self.state).0.id()
    }
}

struct SpawnedSsh {
    process: Arc<SshProcess>,
    stdin: ChildStdin,
    stdout: ChildStdout,
    stderr: StderrLog,
}

fn spawn_ssh(args: Vec<OsString>, options: &SshOptions) -> Result<SpawnedSsh, SshFailure> {
    let mut command = Command::new(&options.program);
    command
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        // Never show a graphical password prompt, whatever the environment says.
        .env_remove("SSH_ASKPASS")
        .env("SSH_ASKPASS_REQUIRE", "never")
        .env_remove("DISPLAY")
        // Its own process group: Ctrl-C reaches Mooring, which then stops ssh
        // in order. ssh still exits on its own if Mooring disappears, because
        // its stdin and stdout are pipes from this process.
        .process_group(0);
    let mut child = command.spawn().map_err(|error| {
        SshFailure::new(
            SshFailureKind::SshUnavailable,
            format!("Could not start {}: {error}", options.program.display()),
        )
    })?;
    let (Some(stdin), Some(stdout), Some(stderr)) =
        (child.stdin.take(), child.stdout.take(), child.stderr.take())
    else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(SshFailure::new(
            SshFailureKind::SshUnavailable,
            "Could not connect to ssh's input and output.".into(),
        ));
    };
    Ok(SpawnedSsh {
        process: Arc::new(SshProcess {
            state: Mutex::new((child, None)),
            stopped_by_mooring: AtomicBool::new(false),
        }),
        stdin,
        stdout,
        stderr: StderrLog::start(stderr),
    })
}

/// Common names for RFB security types, for display only.
pub fn security_type_name(id: u8) -> &'static str {
    match id {
        1 => "None",
        2 => "VNC password",
        5 => "RA2",
        6 => "RA2ne",
        16 => "Tight",
        18 => "TLS",
        19 => "VeNCrypt",
        30 => "Apple Diffie-Hellman",
        129 => "RSA-AES-256",
        _ => "Unknown",
    }
}

/// The security type macOS Screen Sharing signs in with to a server that is
/// not a Mac: a VNC password. On macOS 27.0.1 it chose type 2 for an RFB 3.8
/// server that offered only [129, 5, 30], and failed; it did not use Apple
/// Diffie-Hellman (30) there, though that type is offered.
const APPLE_VIEWER_TYPES: [u8; 1] = [2];

/// What the pre-flight check learned through SSH, before any sign-in.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RouteCheck {
    pub ssh_target: String,
    pub remote_host: String,
    pub remote_port: u16,
    /// For example `003.008` (wayvnc) or `003.889` (a Mac).
    pub rfb_version: String,
    pub security_types: Vec<u8>,
    pub security_type_names: Vec<&'static str>,
    /// SSH setup plus the server's greeting, measured from starting ssh.
    pub greeting_ms: f64,
    pub looks_like_mac: bool,
    /// Whether macOS Screen Sharing is expected to be able to sign in: the
    /// server is a Mac, or offers a VNC password (type 2).
    pub apple_viewer_compatible: bool,
    pub note: String,
}

#[derive(Debug)]
enum RfbError {
    /// The stream ended after `received` bytes; ssh usually says why.
    Closed {
        received: usize,
    },
    Invalid(String),
    Refused(String),
}

fn read_full(
    reader: &mut impl Read,
    buffer: &mut [u8],
    received: &mut usize,
) -> Result<(), RfbError> {
    let mut filled = 0;
    while filled < buffer.len() {
        match reader.read(&mut buffer[filled..]) {
            Ok(0) => {
                return Err(RfbError::Closed {
                    received: *received,
                });
            }
            Ok(size) => {
                filled += size;
                *received += size;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => {
                return Err(RfbError::Closed {
                    received: *received,
                });
            }
        }
    }
    Ok(())
}

fn read_refusal(reader: &mut impl Read, received: &mut usize) -> RfbError {
    let mut length = [0_u8; 4];
    if let Err(error) = read_full(reader, &mut length, received) {
        return error;
    }
    let length = (u32::from_be_bytes(length) as usize).min(MAX_REFUSAL_REASON_BYTES);
    let mut reason = vec![0_u8; length];
    match read_full(reader, &mut reason, received) {
        Ok(()) => RfbError::Refused(sanitize_line(&reason)),
        Err(error) => error,
    }
}

/// Read the greeting, answer with a version, read the offered security types,
/// then stop. Mooring never selects a security type, so no sign-in starts.
fn rfb_preamble(
    mut reader: impl Read,
    mut writer: impl Write,
) -> Result<(String, Vec<u8>, Instant), RfbError> {
    let mut received = 0;
    let mut greeting = [0_u8; 12];
    read_full(&mut reader, &mut greeting, &mut received)?;
    let greeted = Instant::now();
    let version = parse_greeting(&greeting).map_err(RfbError::Invalid)?;
    let (major, minor) = version
        .split_once('.')
        .and_then(|(major, minor)| Some((major.parse::<u32>().ok()?, minor.parse::<u32>().ok()?)))
        .ok_or_else(|| RfbError::Invalid("Invalid RFB version.".into()))?;
    let reply: &[u8; 12] = if (major, minor) >= (3, 8) {
        b"RFB 003.008\n"
    } else if (major, minor) >= (3, 7) {
        b"RFB 003.007\n"
    } else {
        b"RFB 003.003\n"
    };
    if writer.write_all(reply).is_err() {
        return Err(RfbError::Closed { received });
    }
    let types = if reply == b"RFB 003.003\n" {
        // RFB 3.3: the server picks one type, or 0 followed by a reason.
        let mut chosen = [0_u8; 4];
        read_full(&mut reader, &mut chosen, &mut received)?;
        match u32::from_be_bytes(chosen) {
            0 => return Err(read_refusal(&mut reader, &mut received)),
            id => vec![u8::try_from(id).unwrap_or(u8::MAX)],
        }
    } else {
        let mut count = [0_u8; 1];
        read_full(&mut reader, &mut count, &mut received)?;
        if count[0] == 0 {
            return Err(read_refusal(&mut reader, &mut received));
        }
        let mut types = vec![0_u8; usize::from(count[0])];
        read_full(&mut reader, &mut types, &mut received)?;
        types
    };
    Ok((version, types, greeted))
}

fn describe_check(rfb_version: &str, types: &[u8]) -> (bool, bool, String) {
    let looks_like_mac = rfb_version == "003.889";
    let compatible = looks_like_mac || types.iter().any(|id| APPLE_VIEWER_TYPES.contains(id));
    let mut note = String::from(
        "Reached the VNC server through SSH and read its offered security types without signing in. This does not measure bandwidth or video latency.",
    );
    if !compatible {
        note.push_str(" macOS Screen Sharing signs in to servers that are not Macs only with a VNC password (type 2), which this server does not offer, so it will likely fail to sign in. On macOS 27 it did not use Apple Diffie-Hellman (30) with such a server. Another viewer can use the tunnel with connect --no-viewer.");
    }
    (looks_like_mac, compatible, note)
}

fn failure_from_exit(
    route: &SshRoute,
    status: Option<ExitStatus>,
    output: Vec<String>,
    fallback: SshFailure,
) -> SshFailure {
    classify_ssh_output(route, &output)
        .unwrap_or(fallback)
        .with_output(status, output)
}

/// Reach the VNC server through one `ssh -W`, read its greeting and offered
/// security types, then close. `timeout` bounds the whole check, including
/// ssh's own connection and key sign-in; ssh is always stopped and reaped.
pub fn check_route(
    route: &SshRoute,
    options: &SshOptions,
    timeout: Duration,
) -> Result<RouteCheck, SshFailure> {
    check_route_until(route, options, timeout, &|| false)
}

/// [`check_route`] that also gives up as soon as `should_stop` returns true.
fn check_route_until(
    route: &SshRoute,
    options: &SshOptions,
    timeout: Duration,
    should_stop: &dyn Fn() -> bool,
) -> Result<RouteCheck, SshFailure> {
    let started = Instant::now();
    let SpawnedSsh {
        process,
        stdin,
        stdout,
        stderr,
    } = spawn_ssh(ssh_forward_args(route, options), options)?;
    let (sender, receiver) = mpsc::sync_channel(1);
    let conversation = thread::Builder::new()
        .name("mooring-ssh-check".into())
        .spawn(move || {
            // stdin is dropped when this returns, which ends the forward.
            let _ = sender.send(rfb_preamble(stdout, stdin));
        });
    let deadline = started + timeout;
    let mut stopped = false;
    let outcome = match &conversation {
        Ok(_) => loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match receiver.recv_timeout(left.min(TICK)) {
                Ok(result) => break Some(result),
                Err(mpsc::RecvTimeoutError::Disconnected) => break None,
                Err(mpsc::RecvTimeoutError::Timeout) if left.is_zero() => break None,
                Err(mpsc::RecvTimeoutError::Timeout) if should_stop() => {
                    stopped = true;
                    break None;
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
        },
        Err(_) => None,
    };
    let grace = match &outcome {
        Some(Ok(_)) | Some(Err(RfbError::Closed { .. })) => Duration::from_millis(1500),
        _ => Duration::ZERO,
    };
    let status = process.finish(grace);
    if let Ok(handle) = conversation {
        let _ = handle.join();
    }
    let output = stderr.collect(Duration::from_millis(500));
    let status = Some(status);
    match outcome {
        Some(Ok((rfb_version, security_types, greeted))) => {
            let (looks_like_mac, apple_viewer_compatible, note) =
                describe_check(&rfb_version, &security_types);
            Ok(RouteCheck {
                ssh_target: route.target.clone(),
                remote_host: route.remote_host.clone(),
                remote_port: route.remote_port,
                security_type_names: security_types
                    .iter()
                    .map(|id| security_type_name(*id))
                    .collect(),
                rfb_version,
                security_types,
                greeting_ms: greeted.duration_since(started).as_secs_f64() * 1000.0,
                looks_like_mac,
                apple_viewer_compatible,
                note,
            })
        }
        Some(Err(RfbError::Closed { received })) => {
            let fallback = if received == 0 {
                SshFailure::new(
                    SshFailureKind::Other,
                    format!(
                        "ssh ended before the VNC server at {} answered.",
                        route.remote_spec()
                    ),
                )
            } else {
                SshFailure::new(
                    SshFailureKind::NotVnc,
                    format!(
                        "The connection to {} closed during the VNC greeting.",
                        route.remote_spec()
                    ),
                )
            };
            Err(failure_from_exit(route, status, output, fallback))
        }
        Some(Err(RfbError::Invalid(message))) => Err(SshFailure::new(
            SshFailureKind::NotVnc,
            format!(
                "SSH connected, but {} is not a VNC server: {message}",
                route.remote_spec()
            ),
        )
        .with_output(status, output)),
        Some(Err(RfbError::Refused(reason))) => Err(SshFailure::new(
            SshFailureKind::ServerRefused,
            format!("The VNC server refused the connection before sign-in: {reason}"),
        )
        .with_output(status, output)),
        None if stopped => Err(SshFailure::new(
            SshFailureKind::Other,
            "Stopped before the SSH check finished.".into(),
        )
        .with_output(status, output)),
        None => Err(failure_from_exit(
            route,
            status,
            output,
            SshFailure::new(
                SshFailureKind::TimedOut,
                format!(
                    "The SSH route to {} did not answer within {} seconds.",
                    route.target,
                    timeout.as_secs()
                ),
            ),
        )),
    }
}

/// Everything a supervised tunnel needs. Construct with [`TunnelConfig::new`].
#[derive(Debug, Clone)]
pub struct TunnelConfig {
    pub route: SshRoute,
    pub ssh: SshOptions,
    pub limits: TunnelLimits,
    /// Bound for each pre-flight check attempt.
    pub check_timeout: Duration,
}

impl TunnelConfig {
    pub fn new(route: SshRoute) -> Self {
        Self {
            route,
            ssh: SshOptions::default(),
            limits: TunnelLimits::default(),
            check_timeout: Duration::from_secs(20),
        }
    }
}

/// The tunnel is listening and checked; open the viewer at `local_port`.
#[derive(Debug, Clone, Serialize)]
pub struct TunnelReady {
    pub local_host: &'static str,
    pub local_port: u16,
    pub check: RouteCheck,
}

/// Progress reports, in order. Serialized as JSON lines by the CLI.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum TunnelEvent {
    Checking {
        attempt: u32,
    },
    CheckRetry {
        attempt: u32,
        delay_ms: u64,
        error: SshFailure,
    },
    Ready(TunnelReady),
    ViewerOpened {
        url: String,
    },
    ConnectionOpened {
        connections: u32,
        accepted: u32,
    },
    ConnectionRefused {
        reason: Admission,
    },
    ConnectionClosed {
        tunnel: TunnelPhase,
        failed: bool,
        duration_ms: u64,
        bytes_to_server: u64,
        bytes_to_viewer: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<SshFailure>,
    },
}

/// How a supervised tunnel ended. No ssh process outlives this value.
#[derive(Debug, Clone, Serialize)]
pub struct TunnelOutcome {
    pub reason: CloseReason,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<SshFailure>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_port: Option<u16>,
    pub accepted_connections: u32,
    pub failed_connections: u32,
    pub duration_ms: u64,
}

struct RelayOutcome {
    failed: bool,
    duration_ms: u64,
    bytes_to_server: u64,
    bytes_to_viewer: u64,
    error: Option<SshFailure>,
}

struct Worker {
    viewer: TcpStream,
    process: Arc<SshProcess>,
    handle: JoinHandle<()>,
}

fn pump(mut from: impl Read, mut to: impl Write, counter: &AtomicU64) {
    let mut buffer = vec![0_u8; RELAY_BUFFER_BYTES];
    loop {
        let size = match from.read(&mut buffer) {
            Ok(0) => return,
            Ok(size) => size,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        };
        if to.write_all(&buffer[..size]).is_err() {
            return;
        }
        counter.fetch_add(size as u64, Ordering::Relaxed);
    }
}

/// Relay one viewer connection through its own ssh until either side ends.
fn relay(route: &SshRoute, viewer: TcpStream, ssh: SpawnedSsh) -> RelayOutcome {
    let started = Instant::now();
    let SpawnedSsh {
        process,
        stdin,
        stdout,
        stderr,
    } = ssh;
    let to_server = Arc::new(AtomicU64::new(0));
    let to_viewer = Arc::new(AtomicU64::new(0));
    let upload = viewer.try_clone().ok().and_then(|reader| {
        let process = Arc::clone(&process);
        let counter = Arc::clone(&to_server);
        thread::Builder::new()
            .name("mooring-ssh-up".into())
            .spawn(move || {
                let mut stdin = stdin;
                pump(reader, &mut stdin, &counter);
                drop(stdin);
                // VNC never half-closes: once the viewer has gone, give ssh a
                // moment to close the forward itself, then stop it.
                if process.wait_for(Duration::from_secs(2)).is_none() {
                    process.signal(libc::SIGTERM);
                }
            })
            .ok()
    });
    if upload.is_none() {
        process.signal(libc::SIGTERM);
    }
    pump(stdout, &viewer, &to_viewer);
    let _ = viewer.shutdown(Shutdown::Both);
    if let Some(upload) = upload {
        let _ = upload.join();
    }
    let status = process.finish(Duration::from_millis(500));
    let stopped = process.stopped_by_mooring.load(Ordering::SeqCst);
    let failed = !status.success() && !stopped;
    let error = failed.then(|| {
        let output = stderr.collect(Duration::from_millis(500));
        failure_from_exit(
            route,
            Some(status),
            output,
            SshFailure::new(
                SshFailureKind::Other,
                format!("ssh to {} ended with {status}.", route.target),
            ),
        )
    });
    RelayOutcome {
        failed,
        duration_ms: started.elapsed().as_millis() as u64,
        bytes_to_server: to_server.load(Ordering::Relaxed),
        bytes_to_viewer: to_viewer.load(Ordering::Relaxed),
        error,
    }
}

fn now_ms(start: Instant) -> u64 {
    start.elapsed().as_millis() as u64
}

/// Sleep until `until`, waking early if asked to stop. Returns false if stopped.
fn wait_until(until: Instant, should_stop: &dyn Fn() -> bool) -> bool {
    while Instant::now() < until {
        if should_stop() {
            return false;
        }
        thread::sleep(TICK.min(until.saturating_duration_since(Instant::now())));
    }
    !should_stop()
}

/// Run one tunnel to completion: check the route, listen on 127.0.0.1, call
/// `on_ready` (which opens the viewer), relay viewer connections, and stop at
/// the lifecycle's deadlines or when `should_stop` returns true. Every ssh it
/// started has been stopped and reaped when this returns.
pub fn run_tunnel(
    config: &TunnelConfig,
    should_stop: &dyn Fn() -> bool,
    on_ready: &mut dyn FnMut(&TunnelReady) -> Result<Option<String>, String>,
    report: &mut dyn FnMut(&TunnelEvent),
) -> TunnelOutcome {
    let start = Instant::now();
    let mut outcome = TunnelOutcome {
        reason: CloseReason::CheckFailed,
        error: None,
        local_port: None,
        accepted_connections: 0,
        failed_connections: 0,
        duration_ms: 0,
    };
    let mut lifecycle = match TunnelLifecycle::new(config.limits, 0) {
        Ok(lifecycle) => lifecycle,
        Err(error) => {
            outcome.error = Some(SshFailure::new(
                SshFailureKind::InvalidRoute,
                format!("Invalid tunnel limits: {error:?}"),
            ));
            return outcome;
        }
    };
    // Bind first so a local failure is reported before SSH is contacted. The
    // port is held for the whole session, so nothing else can take it.
    let listener = match TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))
        .and_then(|listener| listener.set_nonblocking(true).map(|()| listener))
    {
        Ok(listener) => listener,
        Err(error) => {
            outcome.error = Some(SshFailure::new(
                SshFailureKind::Other,
                format!("Could not listen on 127.0.0.1: {error}"),
            ));
            return outcome;
        }
    };
    let local_port = listener.local_addr().map(|a| a.port()).unwrap_or(0);

    // Pre-flight check, retried only for transient failures.
    let mut attempt = 1;
    let check = loop {
        report(&TunnelEvent::Checking { attempt });
        match check_route_until(
            &config.route,
            &config.ssh,
            config.check_timeout,
            should_stop,
        ) {
            Ok(check) => {
                lifecycle.check_succeeded(now_ms(start));
                break check;
            }
            Err(_) if should_stop() => {
                outcome.reason = lifecycle.cancel();
                outcome.duration_ms = now_ms(start);
                return outcome;
            }
            Err(error) => match lifecycle.check_failed(now_ms(start), error.transient) {
                CheckDecision::Retry {
                    attempt: next,
                    due_at_ms,
                } => {
                    let delay_ms = due_at_ms.saturating_sub(now_ms(start));
                    report(&TunnelEvent::CheckRetry {
                        attempt: next,
                        delay_ms,
                        error,
                    });
                    if !wait_until(start + Duration::from_millis(due_at_ms), should_stop) {
                        outcome.reason = lifecycle.cancel();
                        outcome.duration_ms = now_ms(start);
                        return outcome;
                    }
                    attempt = next;
                }
                CheckDecision::Close { reason } => {
                    outcome.reason = reason;
                    outcome.error = Some(error);
                    outcome.duration_ms = now_ms(start);
                    return outcome;
                }
            },
        }
        if should_stop() {
            outcome.reason = lifecycle.cancel();
            outcome.duration_ms = now_ms(start);
            return outcome;
        }
    };
    outcome.local_port = Some(local_port);
    let ready = TunnelReady {
        local_host: "127.0.0.1",
        local_port,
        check,
    };
    report(&TunnelEvent::Ready(ready.clone()));
    if should_stop() {
        lifecycle.cancel();
    } else {
        match on_ready(&ready) {
            Ok(Some(url)) => report(&TunnelEvent::ViewerOpened { url }),
            Ok(None) => {}
            Err(message) => {
                lifecycle.viewer_launch_failed();
                outcome.error = Some(SshFailure::new(SshFailureKind::Other, message));
            }
        }
    }

    let (done_sender, done_receiver) = mpsc::channel::<(usize, RelayOutcome)>();
    let mut workers: Vec<Option<Worker>> = Vec::new();
    while !lifecycle.is_closed() {
        loop {
            match listener.accept() {
                Ok((viewer, _)) => {
                    match lifecycle.admit(now_ms(start)) {
                        Admission::Accept => {}
                        refused => {
                            drop(viewer);
                            report(&TunnelEvent::ConnectionRefused { reason: refused });
                            continue;
                        }
                    }
                    // Accepted sockets inherit non-blocking mode on macOS.
                    let _ = viewer.set_nonblocking(false);
                    let _ = viewer.set_nodelay(true);
                    let index = workers.len();
                    let started = match (
                        viewer.try_clone(),
                        spawn_ssh(ssh_forward_args(&config.route, &config.ssh), &config.ssh),
                    ) {
                        (Ok(handle), Ok(ssh)) => {
                            let process = Arc::clone(&ssh.process);
                            let route = config.route.clone();
                            let sender = done_sender.clone();
                            thread::Builder::new()
                                .name("mooring-ssh-relay".into())
                                .spawn(move || {
                                    let result = relay(&route, viewer, ssh);
                                    let _ = sender.send((index, result));
                                })
                                .map(|thread| Worker {
                                    viewer: handle,
                                    process,
                                    handle: thread,
                                })
                                .map_err(|error| {
                                    SshFailure::new(
                                        SshFailureKind::Other,
                                        format!("Could not start a relay: {error}"),
                                    )
                                })
                        }
                        (Err(error), _) => Err(SshFailure::new(
                            SshFailureKind::Other,
                            format!("Could not use the viewer connection: {error}"),
                        )),
                        (_, Err(error)) => Err(error),
                    };
                    match started {
                        Ok(worker) => {
                            workers.push(Some(worker));
                            if let TunnelPhase::Active { connections } = lifecycle.phase() {
                                report(&TunnelEvent::ConnectionOpened {
                                    connections,
                                    accepted: lifecycle.accepted_connections(),
                                });
                            }
                        }
                        Err(error) => {
                            workers.push(None);
                            outcome.failed_connections += 1;
                            let phase = lifecycle.connection_closed(now_ms(start), true);
                            report(&TunnelEvent::ConnectionClosed {
                                tunnel: phase,
                                failed: true,
                                duration_ms: 0,
                                bytes_to_server: 0,
                                bytes_to_viewer: 0,
                                error: Some(error),
                            });
                        }
                    }
                    if lifecycle.is_closed() {
                        break;
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => break,
            }
        }
        match done_receiver.recv_timeout(TICK) {
            Ok((index, result)) => {
                if let Some(worker) = workers.get_mut(index).and_then(Option::take) {
                    let _ = worker.handle.join();
                }
                if result.failed {
                    outcome.failed_connections += 1;
                }
                let phase = lifecycle.connection_closed(now_ms(start), result.failed);
                report(&TunnelEvent::ConnectionClosed {
                    tunnel: phase,
                    failed: result.failed,
                    duration_ms: result.duration_ms,
                    bytes_to_server: result.bytes_to_server,
                    bytes_to_viewer: result.bytes_to_viewer,
                    error: result.error,
                });
            }
            Err(mpsc::RecvTimeoutError::Timeout) | Err(mpsc::RecvTimeoutError::Disconnected) => {}
        }
        if should_stop() {
            lifecycle.cancel();
        }
        lifecycle.poll(now_ms(start));
    }
    drop(listener);

    // Teardown: close every viewer socket and stop every ssh, then reap them.
    let live: Vec<Worker> = workers.into_iter().flatten().collect();
    for worker in &live {
        let _ = worker.viewer.shutdown(Shutdown::Both);
        worker.process.signal(libc::SIGTERM);
    }
    for worker in live {
        let pid = worker.process.pid();
        let _ = worker.handle.join();
        debug_assert!(
            worker.process.status().is_some(),
            "ssh {pid} was not reaped"
        );
    }
    if let TunnelPhase::Closed { reason } = lifecycle.phase() {
        outcome.reason = reason;
    }
    outcome.accepted_connections = lifecycle.accepted_connections();
    outcome.duration_ms = now_ms(start);
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    pub(super) struct Fixture(pub(super) PathBuf);

    impl Fixture {
        pub(super) fn new(name: &str) -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let path = std::env::temp_dir().join(format!(
                "mooring-ssh-{name}-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        /// A fake ssh: records its argv and pid, then runs `body` in sh.
        pub(super) fn fake_ssh(&self, body: &str) -> SshOptions {
            let script = self.0.join("ssh");
            let dir = self.0.display();
            fs::write(
                &script,
                format!(
                    "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{dir}/args'\necho $$ >> '{dir}/pids'\n{body}\n"
                ),
            )
            .unwrap();
            fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
            SshOptions {
                program: script,
                config_file: None,
                connect_timeout_secs: 5,
            }
        }

        pub(super) fn pids(&self) -> Vec<i32> {
            fs::read_to_string(self.0.join("pids"))
                .unwrap_or_default()
                .lines()
                .filter_map(|line| line.trim().parse().ok())
                .collect()
        }

        pub(super) fn assert_no_survivors(&self) {
            for pid in self.pids() {
                // SAFETY: signal 0 only checks whether the process exists.
                let alive = unsafe { libc::kill(pid, 0) } == 0;
                assert!(!alive, "fake ssh {pid} outlived the tunnel");
            }
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// Behaves like wayvnc behind `ssh -W`: greeting, read the client
    /// version, offer [129, 5, 30], then hold until the client leaves.
    const WAYVNC: &str = "printf 'RFB 003.008\\n'\nhead -c 12 >/dev/null\nprintf '\\003\\201\\005\\036'\ncat >/dev/null";

    fn route() -> SshRoute {
        SshRoute::new("m1-linux", "127.0.0.1", 5900).unwrap()
    }

    #[test]
    fn accepts_aliases_users_and_addresses() {
        for target in [
            "m1-linux",
            "alex@192.0.2.20",
            "root@m1-linux",
            "my_box",
            "host.example.com",
            "_svc@host",
            "first.last@host-1.local",
            "::1",
            "user@2001:db8::1",
            "192.168.1.10",
        ] {
            assert_eq!(validate_ssh_target(target).unwrap(), target);
        }
    }

    #[test]
    fn rejects_option_injection_and_ambiguous_targets() {
        for target in [
            "",
            "-oProxyCommand=id",
            "-o",
            "host -oProxyCommand=id",
            "host\t-v",
            "-l root host",
            "--",
            "user@-host",
            "-user@host",
            "@host",
            "user@",
            "user@@host",
            "a@b@c",
            "host:22",
            "user@host:22",
            "ssh://host",
            "host/path",
            "host;id",
            "$(id)",
            "`id`",
            "host%h",
            "'host'",
            "host\n",
            " host",
            ".host",
            "host..local",
            "hóst",
            "127.1",
            "[::1]",
            "user:pass@host",
        ] {
            assert!(validate_ssh_target(target).is_err(), "accepted {target:?}");
        }
        assert!(validate_ssh_target(&"a".repeat(256)).is_err());
        assert!(validate_ssh_target(&format!("{}@host", "u".repeat(65))).is_err());
    }

    #[test]
    fn routes_validate_the_remote_endpoint() {
        assert_eq!(route().remote_spec(), "127.0.0.1:5900");
        assert_eq!(
            SshRoute::new("m1-linux", "::1", 5901)
                .unwrap()
                .remote_spec(),
            "[::1]:5901"
        );
        assert_eq!(
            SshRoute::new("bastion", "Desk.Local", 5900)
                .unwrap()
                .remote_host,
            "desk.local"
        );
        assert!(SshRoute::new("m1-linux", "127.0.0.1", 0).is_err());
        assert!(SshRoute::new("m1-linux", "127.0.0.1:5900", 5900).is_err());
        assert!(SshRoute::new("m1-linux", "-oProxyCommand=id", 5900).is_err());
        assert!(SshRoute::new("-m1", "127.0.0.1", 5900).is_err());
    }

    #[test]
    fn builds_a_fixed_argv_with_the_destination_after_double_dash() {
        let args: Vec<String> = ssh_forward_args(&route(), &SshOptions::default())
            .into_iter()
            .map(|arg| arg.into_string().unwrap())
            .collect();
        let tail: Vec<&str> = args[args.len() - 4..].iter().map(String::as_str).collect();
        assert_eq!(tail, ["-W", "127.0.0.1:5900", "--", "m1-linux"]);
        for required in [
            "BatchMode=yes",
            "PasswordAuthentication=no",
            "KbdInteractiveAuthentication=no",
            "ConnectTimeout=6",
            "ServerAliveInterval=15",
            "ExitOnForwardFailure=yes",
            "ClearAllForwardings=yes",
            "ControlMaster=no",
            "ControlPersist=no",
            "PermitLocalCommand=no",
        ] {
            let position = args.iter().position(|arg| arg == required);
            assert!(position.is_some(), "missing {required}");
            assert_eq!(args[position.unwrap() - 1], "-o");
        }
        // No listening forward and no remote command.
        assert!(
            !args
                .iter()
                .any(|arg| arg == "-L" || arg == "-R" || arg == "-D")
        );
        assert!(!args.iter().any(|arg| arg == "-F"));
        let isolated = SshOptions {
            config_file: Some(PathBuf::from("/tmp/isolated config")),
            connect_timeout_secs: 500,
            ..SshOptions::default()
        };
        let args = ssh_forward_args(&route(), &isolated);
        assert_eq!(args[0], "-F");
        assert_eq!(args[1], "/tmp/isolated config", "one argv entry, no shell");
        assert!(args.iter().any(|arg| arg == "ConnectTimeout=60"));
    }

    #[test]
    fn classifies_real_ssh_messages() {
        let route = route();
        let kind = |text: &str| {
            classify_ssh_output(&route, &[text.to_string()]).map(|failure| failure.kind)
        };
        use SshFailureKind as K;
        assert_eq!(
            kind(
                "ssh: Could not resolve hostname nosuchhost.invalid: nodename nor servname provided, or not known"
            ),
            Some(K::HostNotFound)
        );
        assert_eq!(
            kind("channel 0: open failed: connect failed: Connection refused"),
            Some(K::RemotePortClosed)
        );
        assert_eq!(kind("stdio forwarding failed"), Some(K::RemotePortClosed));
        assert_eq!(
            kind("channel 0: open failed: administratively prohibited: open failed"),
            Some(K::ForwardingDenied)
        );
        assert_eq!(
            kind("alex@192.0.2.20: Permission denied (publickey,password)."),
            Some(K::AuthenticationFailed)
        );
        assert_eq!(
            kind("Host key verification failed."),
            Some(K::HostKeyUnknown)
        );
        assert_eq!(
            kind("@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @"),
            Some(K::HostKeyChanged)
        );
        assert_eq!(
            kind("ssh: connect to host 192.0.2.1 port 22: Operation timed out"),
            Some(K::HostUnreachable)
        );
        assert_eq!(
            kind("ssh: connect to host 192.0.2.20 port 22: Connection refused"),
            Some(K::SshPortRefused)
        );
        assert_eq!(
            kind("Timeout, server m1-linux not responding."),
            Some(K::HostUnreachable)
        );
        let dropped = classify_ssh_output(
            &route,
            &["kex_exchange_identification: Connection closed by remote host".into()],
        )
        .unwrap();
        assert_eq!(dropped.kind, K::ConnectionDropped);
        assert!(dropped.transient);
        assert_eq!(
            kind("command-line line 0: Bad configuration option: kbdinteractiveauthentication"),
            Some(K::SshConfig)
        );
        assert_eq!(
            kind(
                "Warning: Permanently added '192.0.2.20' (ED25519) to the list of known hosts."
            ),
            None
        );
        let auth = classify_ssh_output(&route, &["Permission denied (publickey).".into()]).unwrap();
        assert!(!auth.transient, "a missing key must not be retried");
        assert!(auth.message.contains("never asks for a password"));
    }

    #[test]
    fn sanitizes_ssh_output() {
        assert_eq!(sanitize_line(b"\x1b[31mred\x07\tok  "), "?[31mred? ok");
        assert_eq!(sanitize_line(&[b'a'; 1000]).len(), STDERR_LINE_BYTES);
        assert_eq!(sanitize_line("é".as_bytes()), "??");
    }

    #[test]
    fn preamble_reads_security_types_without_choosing_one() {
        let mut sent = Vec::new();
        let input: &[u8] = b"RFB 003.008\n\x03\x81\x05\x1e";
        let (version, types, _) = rfb_preamble(input, &mut sent).unwrap();
        assert_eq!(version, "003.008");
        assert_eq!(types, [129, 5, 30]);
        assert_eq!(sent, b"RFB 003.008\n", "only the version is ever sent");

        let mut sent = Vec::new();
        let (version, types, _) =
            rfb_preamble(&b"RFB 003.889\n\x02\x1e\x23"[..], &mut sent).unwrap();
        assert_eq!((version.as_str(), types), ("003.889", vec![30, 35]));
        assert_eq!(sent, b"RFB 003.008\n");

        let mut sent = Vec::new();
        let (_, types, _) = rfb_preamble(&b"RFB 003.003\n\x00\x00\x00\x02"[..], &mut sent).unwrap();
        assert_eq!((types, sent.as_slice()), (vec![2], &b"RFB 003.003\n"[..]));

        let refused = rfb_preamble(
            &b"RFB 003.008\n\x00\x00\x00\x00\x12Too many\x1b failures"[..],
            Vec::new(),
        );
        assert!(
            matches!(refused, Err(RfbError::Refused(reason)) if reason == "Too many? failures")
        );
        assert!(matches!(
            rfb_preamble(&b"SSH-2.0-Open"[..], Vec::new()),
            Err(RfbError::Invalid(_))
        ));
        assert!(matches!(
            rfb_preamble(&b"RFB 003"[..], Vec::new()),
            Err(RfbError::Closed { received: 7 })
        ));
        assert!(matches!(
            rfb_preamble(&b""[..], Vec::new()),
            Err(RfbError::Closed { received: 0 })
        ));
    }

    #[test]
    fn notes_servers_screen_sharing_cannot_sign_in_to() {
        // wayvnc with relax_encryption: Screen Sharing on macOS 27 tried only
        // a VNC password here and failed, so this is not compatible.
        let (mac, compatible, note) = describe_check("003.008", &[129, 5, 30]);
        assert!(!mac && !compatible && note.contains("VNC password (type 2)"));
        assert!(note.contains("--no-viewer"));
        let (_, compatible, note) = describe_check("003.008", &[2, 129]);
        assert!(compatible && !note.contains("type 2"));
        let (mac, compatible, _) = describe_check("003.889", &[35]);
        assert!(mac && compatible);
    }

    #[test]
    fn check_passes_args_without_a_shell_and_reaps_ssh() {
        let fixture = Fixture::new("check");
        let options = fixture.fake_ssh(WAYVNC);
        let check = check_route(&route(), &options, Duration::from_secs(5)).unwrap();
        assert_eq!(check.rfb_version, "003.008");
        assert_eq!(check.security_types, [129, 5, 30]);
        assert_eq!(
            check.security_type_names,
            ["RSA-AES-256", "RA2", "Apple Diffie-Hellman"]
        );
        assert!(!check.apple_viewer_compatible && !check.looks_like_mac);
        let args = fs::read_to_string(fixture.0.join("args")).unwrap();
        let expected: Vec<String> = ssh_forward_args(&route(), &options)
            .into_iter()
            .map(|arg| arg.into_string().unwrap())
            .collect();
        assert_eq!(args.lines().collect::<Vec<_>>(), expected);
        fixture.assert_no_survivors();
    }

    #[test]
    fn check_failures_are_readable_and_fast() {
        for (body, kind) in [
            (
                "echo 'alex@m1-linux: Permission denied (publickey).' >&2; exit 255",
                SshFailureKind::AuthenticationFailed,
            ),
            (
                "echo 'ssh: Could not resolve hostname nope: nodename nor servname provided, or not known' >&2; exit 255",
                SshFailureKind::HostNotFound,
            ),
            (
                "echo 'channel 0: open failed: connect failed: Connection refused' >&2; echo 'stdio forwarding failed' >&2; exit 255",
                SshFailureKind::RemotePortClosed,
            ),
            ("printf 'HTTP/1.1 400 Bad'", SshFailureKind::NotVnc),
            ("exit 255", SshFailureKind::Other),
        ] {
            let fixture = Fixture::new("fail");
            let started = Instant::now();
            let error =
                check_route(&route(), &fixture.fake_ssh(body), Duration::from_secs(5)).unwrap_err();
            assert_eq!(error.kind, kind, "{body}: {error:?}");
            assert!(!error.message.is_empty());
            assert!(
                started.elapsed() < Duration::from_secs(4),
                "{body} was slow"
            );
            fixture.assert_no_survivors();
        }
    }

    #[test]
    fn a_hung_ssh_is_stopped_at_the_deadline() {
        let fixture = Fixture::new("hang");
        // Ignores SIGTERM, so the SIGKILL fallback must reap it.
        let options = fixture.fake_ssh("trap '' TERM\nwhile :; do sleep 1; done");
        let started = Instant::now();
        let error = check_route(&route(), &options, Duration::from_millis(300)).unwrap_err();
        assert_eq!(error.kind, SshFailureKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(3));
        fixture.assert_no_survivors();
    }

    #[test]
    fn a_missing_program_is_reported() {
        let options = SshOptions {
            program: PathBuf::from("/nonexistent/ssh"),
            ..SshOptions::default()
        };
        let error = check_route(&route(), &options, Duration::from_secs(1)).unwrap_err();
        assert_eq!(error.kind, SshFailureKind::SshUnavailable);
    }

    struct Run {
        events: Vec<String>,
        outcome: TunnelOutcome,
    }

    fn run_with(
        options: SshOptions,
        limits: TunnelLimits,
        stop: Arc<AtomicBool>,
        on_port: impl FnOnce(u16) + Send + 'static,
    ) -> Run {
        let mut config = TunnelConfig::new(route());
        config.ssh = options;
        config.limits = limits;
        config.check_timeout = Duration::from_secs(5);
        let mut on_port = Some(on_port);
        let mut events = Vec::new();
        let outcome = run_tunnel(
            &config,
            &|| stop.load(Ordering::SeqCst),
            &mut |ready| {
                let port = ready.local_port;
                let callback = on_port.take().unwrap();
                thread::spawn(move || callback(port));
                Ok(Some(format!("vnc://127.0.0.1:{port}")))
            },
            &mut |event| {
                let text = format!("{event:?}");
                events.push(text.split([' ', '(', '{']).next().unwrap().to_owned());
            },
        );
        Run { events, outcome }
    }

    fn short_limits() -> TunnelLimits {
        TunnelLimits {
            first_viewer_timeout_ms: 3_000,
            idle_timeout_ms: 300,
            ..TunnelLimits::default()
        }
    }

    /// A viewer's view of the tunnel: greeting, version, security types.
    fn viewer_handshake(port: u16) -> (Vec<u8>, TcpStream) {
        let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut greeting = [0_u8; 12];
        stream.read_exact(&mut greeting).unwrap();
        assert_eq!(&greeting, b"RFB 003.008\n");
        stream.write_all(b"RFB 003.008\n").unwrap();
        let mut types = [0_u8; 4];
        stream.read_exact(&mut types).unwrap();
        (types.to_vec(), stream)
    }

    #[test]
    fn relays_a_viewer_and_ends_after_the_idle_grace() {
        let fixture = Fixture::new("relay");
        let (sender, receiver) = mpsc::channel();
        let run = run_with(
            fixture.fake_ssh(WAYVNC),
            short_limits(),
            Arc::new(AtomicBool::new(false)),
            move |port| {
                let (types, stream) = viewer_handshake(port);
                drop(stream);
                sender.send(types).unwrap();
            },
        );
        assert_eq!(receiver.recv().unwrap(), [3, 129, 5, 30]);
        assert_eq!(run.outcome.reason, CloseReason::SessionEnded);
        assert_eq!(run.outcome.accepted_connections, 1);
        assert_eq!(run.outcome.failed_connections, 0);
        assert_eq!(
            run.events,
            [
                "Checking",
                "Ready",
                "ViewerOpened",
                "ConnectionOpened",
                "ConnectionClosed"
            ]
        );
        // One ssh for the check and one for the viewer, both reaped.
        assert_eq!(fixture.pids().len(), 2);
        fixture.assert_no_survivors();
        let port = run.outcome.local_port.unwrap();
        assert!(
            TcpStream::connect(("127.0.0.1", port)).is_err(),
            "listener closed"
        );
    }

    #[test]
    fn cancelling_stops_open_connections_and_ssh() {
        let fixture = Fixture::new("cancel");
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        let (sender, receiver) = mpsc::channel();
        let started = Instant::now();
        let run = run_with(
            fixture.fake_ssh(WAYVNC),
            short_limits(),
            stop,
            move |port| {
                let (_, mut stream) = viewer_handshake(port);
                flag.store(true, Ordering::SeqCst);
                // The tunnel closes the viewer's socket during teardown.
                let ended = matches!(stream.read(&mut [0_u8; 16]), Ok(0) | Err(_));
                sender.send(ended).unwrap();
            },
        );
        assert_eq!(run.outcome.reason, CloseReason::Cancelled);
        assert!(receiver.recv_timeout(Duration::from_secs(5)).unwrap());
        assert!(started.elapsed() < Duration::from_secs(5));
        fixture.assert_no_survivors();
    }

    #[test]
    fn a_viewer_that_never_arrives_closes_the_tunnel() {
        let fixture = Fixture::new("noviewer");
        let limits = TunnelLimits {
            first_viewer_timeout_ms: 200,
            ..short_limits()
        };
        let run = run_with(
            fixture.fake_ssh(WAYVNC),
            limits,
            Arc::new(AtomicBool::new(false)),
            |_| {},
        );
        assert_eq!(run.outcome.reason, CloseReason::NoViewer);
        assert_eq!(run.outcome.accepted_connections, 0);
        fixture.assert_no_survivors();
    }

    #[test]
    fn repeated_ssh_failures_close_the_tunnel() {
        let fixture = Fixture::new("repeat");
        let counter = fixture.0.join("count");
        // The check succeeds; every later ssh fails to sign in.
        let body = format!(
            "if [ -e '{0}' ]; then echo 'Permission denied (publickey).' >&2; exit 255; fi\ntouch '{0}'\n{WAYVNC}",
            counter.display()
        );
        let run = run_with(
            fixture.fake_ssh(&body),
            TunnelLimits {
                idle_timeout_ms: 5_000,
                ..short_limits()
            },
            Arc::new(AtomicBool::new(false)),
            |port| {
                for _ in 0..3 {
                    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
                    stream
                        .set_read_timeout(Some(Duration::from_secs(5)))
                        .unwrap();
                    let _ = stream.read(&mut [0_u8; 12]);
                    thread::sleep(Duration::from_millis(100));
                }
            },
        );
        assert_eq!(run.outcome.reason, CloseReason::RepeatedFailures);
        assert_eq!(run.outcome.failed_connections, 3);
        fixture.assert_no_survivors();
    }

    #[test]
    fn a_failed_check_never_listens_for_a_viewer() {
        let fixture = Fixture::new("checkfail");
        let run = run_with(
            fixture.fake_ssh("echo 'Host key verification failed.' >&2; exit 255"),
            short_limits(),
            Arc::new(AtomicBool::new(false)),
            |_| panic!("the viewer must not open"),
        );
        assert_eq!(run.outcome.reason, CloseReason::CheckFailed);
        assert_eq!(
            run.outcome.error.unwrap().kind,
            SshFailureKind::HostKeyUnknown
        );
        assert_eq!(run.events, ["Checking"]);
        assert_eq!(
            fixture.pids().len(),
            1,
            "permanent failures are not retried"
        );
        fixture.assert_no_survivors();
    }

    #[test]
    fn stopping_during_a_slow_check_does_not_wait_for_it() {
        let fixture = Fixture::new("slowcheck");
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        thread::spawn(move || {
            thread::sleep(Duration::from_millis(200));
            flag.store(true, Ordering::SeqCst);
        });
        let started = Instant::now();
        let run = run_with(
            fixture.fake_ssh("exec sleep 30"),
            short_limits(),
            stop,
            |_| {},
        );
        assert_eq!(run.outcome.reason, CloseReason::Cancelled);
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "{:?}",
            started.elapsed()
        );
        fixture.assert_no_survivors();
    }

    #[test]
    fn transient_check_failures_are_retried_once() {
        let fixture = Fixture::new("retry");
        let run = run_with(
            fixture.fake_ssh(
                "echo 'kex_exchange_identification: Connection closed by remote host' >&2; exit 255",
            ),
            TunnelLimits {
                check_retry_delay_ms: 10,
                ..short_limits()
            },
            Arc::new(AtomicBool::new(false)),
            |_| {},
        );
        assert_eq!(run.outcome.reason, CloseReason::CheckFailed);
        assert_eq!(run.events, ["Checking", "CheckRetry", "Checking"]);
        assert_eq!(fixture.pids().len(), 2);
    }
}
