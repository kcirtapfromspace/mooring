//! An owned OpenSSH connection for the Linux viewer's concurrent channels.
//! The caller retains the QUIC bridge. Only the SSH master uses its local port.
use crate::{LinkError, Result, transport};
use std::{
    collections::VecDeque,
    ffi::{CStr, OsString},
    io::Read,
    net::SocketAddr,
    os::unix::{fs::FileTypeExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

const STDERR_BYTES: usize = 8192;

struct PrivateDirectory(PathBuf);
impl PrivateDirectory {
    fn create() -> Result<Self> {
        // A short path also fits the macOS Unix socket address limit.
        let mut pattern = b"/tmp/mooring-ssh-XXXXXX\0".to_vec();
        // SAFETY: mkdtemp receives a writable, terminated template. It creates
        // a new directory with mode 0700; it never reuses an existing path.
        let pointer = unsafe { libc::mkdtemp(pattern.as_mut_ptr().cast()) };
        if pointer.is_null() {
            return Err(transport(std::io::Error::last_os_error()));
        }
        let path = unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .map_err(transport)?;
        Ok(Self(PathBuf::from(path)))
    }
}
impl Drop for PrivateDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct OwnedProcess(Child);
impl OwnedProcess {
    fn spawn(command: &mut Command) -> Result<Self> {
        command.process_group(0);
        command.spawn().map(Self).map_err(transport)
    }
}
impl Drop for OwnedProcess {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_some() {
            return;
        }
        // A separate process group contains only this command and its children.
        // Stop the proxy as well as SSH; no background control master survives.
        unsafe { libc::kill(-(self.0.id() as i32), libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline {
            if self.0.try_wait().ok().flatten().is_some() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        unsafe { libc::kill(-(self.0.id() as i32), libc::SIGKILL) };
        let _ = self.0.wait();
    }
}

fn path_text(path: &Path) -> Result<&str> {
    path.to_str()
        .filter(|text| !text.contains(['\n', '\r', '\0']))
        .ok_or(LinkError::Invalid("SSH paths must contain one UTF-8 line"))
}
fn shell_word(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}
fn config_word(path: &Path) -> Result<String> {
    Ok(format!(
        "\"{}\"",
        path_text(path)?.replace('\\', "\\\\").replace('"', "\\\"")
    ))
}
fn configuration(
    helper: &Path,
    address: SocketAddr,
    target: &str,
    socket: &Path,
    user_config: &Path,
) -> Result<String> {
    mooring_core::connection::validate_ssh_target(target).map_err(transport)?;
    if !address.ip().is_loopback() || address.port() == 0 {
        return Err(LinkError::Invalid("The SSH bridge must use loopback"));
    }
    // OpenSSH matches Host against the hostname, without the user@ prefix.
    let host = target.rsplit_once('@').map_or(target, |(_, host)| host);
    let executable = shell_word(&path_text(helper)?.replace('%', "%%"));
    Ok(format!(
        "Host {host}\n  ProxyCommand {executable} local-proxy {address}\n  ControlPath {}\n  ControlMaster no\n  ControlPersist no\n  StrictHostKeyChecking yes\n  BatchMode yes\n  PasswordAuthentication no\n  KbdInteractiveAuthentication no\n  ForwardAgent no\n  ForwardX11 no\n  PermitLocalCommand no\nHost *\n  Include {}\n",
        config_word(socket)?,
        config_word(user_config)?
    ))
}

struct Session {
    master: OwnedProcess,
    config: PathBuf,
    socket: PathBuf,
    diagnostics: Arc<Mutex<VecDeque<u8>>>,
    _directory: PrivateDirectory,
}
impl Session {
    fn start(
        helper: &Path,
        ssh: &Path,
        address: SocketAddr,
        target: &str,
        user_config: &Path,
    ) -> Result<Self> {
        let directory = PrivateDirectory::create()?;
        let config = directory.0.join("config");
        // OpenSSH expands %C from the host, port, user and local hostname.
        // A command that selects another remote account must not reuse this
        // account's authenticated control connection.
        let socket = directory.0.join("control-%C");
        let text = configuration(helper, address, target, &socket, user_config)?;
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&config)
            .map_err(transport)?;
        file.write_all(text.as_bytes()).map_err(transport)?;
        let mut master = OwnedProcess::spawn(
            Command::new(ssh)
                .args(["-F"])
                .arg(&config)
                .args([
                    "-o",
                    "ConnectionAttempts=1",
                    "-o",
                    "ConnectTimeout=10",
                    "-o",
                    "ServerAliveInterval=10",
                    "-o",
                    "ServerAliveCountMax=3",
                    "-o",
                    "ClearAllForwardings=yes",
                    "-M",
                    "-N",
                    "-S",
                ])
                .arg(&socket)
                .arg("--")
                .arg(target)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::piped()),
        )?;
        let mut stderr = master.0.stderr.take().ok_or(LinkError::Closed)?;
        let diagnostics = Arc::new(Mutex::new(VecDeque::with_capacity(STDERR_BYTES)));
        let output = diagnostics.clone();
        std::thread::spawn(move || {
            let mut buffer = [0u8; 512];
            while let Ok(count) = stderr.read(&mut buffer) {
                if count == 0 {
                    break;
                }
                let Ok(mut output) = output.lock() else {
                    break;
                };
                for byte in &buffer[..count] {
                    if output.len() == STDERR_BYTES {
                        output.pop_front();
                    }
                    output.push_back(*byte);
                }
            }
        });
        Ok(Self {
            master,
            config,
            socket,
            diagnostics,
            _directory: directory,
        })
    }
    fn error(&self) -> LinkError {
        let bytes: Vec<u8> = self
            .diagnostics
            .lock()
            .map(|text| text.iter().copied().collect())
            .unwrap_or_default();
        let message = String::from_utf8_lossy(&bytes);
        LinkError::Transport(format!("SSH session ended. {}", message.trim()))
    }
    async fn ready(&mut self, deadline: Instant) -> Result<()> {
        loop {
            if self.master.0.try_wait().map_err(transport)?.is_some() {
                return Err(self.error());
            }
            let ready = self
                .socket
                .parent()
                .and_then(|directory| std::fs::read_dir(directory).ok())
                .is_some_and(|entries| {
                    entries
                        .take(8)
                        .flatten()
                        .any(|entry| entry.file_type().is_ok_and(|kind| kind.is_socket()))
                });
            if ready {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(LinkError::Timeout);
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }
    async fn command(&mut self, arguments: &[OsString], deadline: Instant) -> Result<ExitStatus> {
        let (program, arguments) = arguments
            .split_first()
            .ok_or(LinkError::Invalid("Supply a command after --"))?;
        let mut child = OwnedProcess::spawn(
            Command::new(program)
                .args(arguments)
                .env("MOORING_SSH_CONFIG", &self.config),
        )?;
        loop {
            if let Some(status) = child.0.try_wait().map_err(transport)? {
                return Ok(status);
            }
            if self.master.0.try_wait().map_err(transport)?.is_some() {
                return Err(self.error());
            }
            if Instant::now() >= deadline {
                return Err(LinkError::Timeout);
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
}

/// Run one command while its SSH channels share one authenticated relay link.
/// The caller must retain the bridge at `address` until this function returns.
pub fn run(
    address: SocketAddr,
    target: &str,
    command: &[OsString],
    session_ms: u64,
) -> Result<ExitStatus> {
    if command.is_empty() {
        return Err(LinkError::Invalid("Supply a command after --"));
    }
    let helper = std::env::current_exe().map_err(transport)?;
    let user_config = if let Some(config) = std::env::var_os("MOORING_SSH_CONFIG") {
        let path = PathBuf::from(config);
        if !path.is_absolute() || !path.is_file() {
            return Err(LinkError::Invalid(
                "MOORING_SSH_CONFIG must name an absolute configuration file",
            ));
        }
        path
    } else {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or(LinkError::Invalid("HOME is unavailable"))?
            .join(".ssh/config")
    };
    let mut session = Session::start(
        &helper,
        Path::new("/usr/bin/ssh"),
        address,
        target,
        &user_config,
    )?;
    crate::blocking::runtime()?.block_on(async {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .map_err(transport)?;
        let mut hangup = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::hangup())
            .map_err(transport)?;
        let operation = async {
            session
                .ready(Instant::now() + Duration::from_secs(15))
                .await?;
            eprintln!("Mooring SSH session ready; the command uses the owned relay connection.");
            session
                .command(command, Instant::now() + Duration::from_millis(session_ms))
                .await
        };
        tokio::select! {
            result = operation => result,
            _ = tokio::signal::ctrl_c() => Err(LinkError::Cancelled),
            _ = terminate.recv() => Err(LinkError::Cancelled),
            _ = hangup.recv() => Err(LinkError::Cancelled),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn configuration_preserves_host_identity_and_rejects_injected_targets() {
        let address = "127.0.0.1:12345".parse().unwrap();
        let text = configuration(
            Path::new("/tmp/Mooring's 100%/mooring-link"),
            address,
            "user@jetson",
            Path::new("/tmp/control"),
            Path::new("/tmp/user config"),
        )
        .unwrap();
        assert!(text.starts_with("Host jetson\n"));
        assert!(text.contains("StrictHostKeyChecking yes"));
        assert!(text.contains("Mooring'\\''s 100%%"));
        assert!(text.contains("Include \"/tmp/user config\""));
        assert!(!text.contains("HostName 127.0.0.1"));
        for target in ["host\nProxyCommand bad", "-oProxyCommand=bad", "host *"] {
            assert!(
                configuration(
                    Path::new("/bin/helper"),
                    address,
                    target,
                    Path::new("/tmp/c"),
                    Path::new("/tmp/u")
                )
                .is_err()
            );
        }
        assert!(
            configuration(
                Path::new("/bin/helper"),
                "192.0.2.1:22".parse().unwrap(),
                "host",
                Path::new("/tmp/c"),
                Path::new("/tmp/u")
            )
            .is_err()
        );
    }
    #[test]
    fn dropping_a_command_reaps_the_owned_process() {
        let mut process = OwnedProcess::spawn(Command::new("/bin/sleep").arg("60")).unwrap();
        let pid = process.0.id();
        assert!(process.0.try_wait().unwrap().is_none());
        drop(process);
        assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
    }
    #[tokio::test]
    async fn early_ssh_failure_removes_private_config_and_does_not_start_the_command() {
        let directory;
        {
            let mut session = Session::start(
                Path::new("/bin/helper"),
                Path::new("/usr/bin/false"),
                "127.0.0.1:12345".parse().unwrap(),
                "host",
                Path::new("/tmp/no-config"),
            )
            .unwrap();
            directory = session._directory.0.clone();
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(
                std::fs::metadata(&session.config)
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
            assert!(
                session
                    .ready(Instant::now() + Duration::from_secs(2))
                    .await
                    .is_err()
            );
        }
        assert!(!directory.exists());
    }
}
