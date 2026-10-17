//! Foreground Hyprland host, using the same authenticated session engine as the Mac app.
mod input;
mod video;
use mooring_session::ffi::*;
use std::ffi::{CStr, CString};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use zeroize::Zeroizing;
static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop(_: i32) {
    STOP.store(true, Ordering::Relaxed);
}
fn check(status: i32) -> Result<(), String> {
    if status == 0 {
        Ok(())
    } else {
        // SAFETY: ABI returns a static NUL-terminated string.
        Err(unsafe { CStr::from_ptr(ml_session_error_string(status)) }
            .to_string_lossy()
            .into_owned())
    }
}
fn cstr(s: &str) -> Result<CString, String> {
    CString::new(s).map_err(|_| "NUL in argument".into())
}
/// Small command output, with a deadline and bounded stdout; never uses a shell.
fn command(program: &str, args: &[&str]) -> Result<Vec<u8>, String> {
    let mut child = ChildGuard(
        Command::new(program)
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| format!("{program}: {e}"))?,
    );
    let mut stdout = child.0.stdout.take().ok_or("missing stdout")?;
    nonblock(&stdout)?;
    let start = Instant::now();
    let mut output = Vec::new();
    let mut buf = [0; 8192];
    loop {
        match stdout.read(&mut buf) {
            Ok(n) => {
                output.extend_from_slice(&buf[..n]);
                if output.len() > 65536 {
                    return Err(format!("{program}: excessive output"));
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e.to_string()),
        }
        if let Some(status) = child.0.try_wait().map_err(|e| e.to_string())? {
            // Drain the final pipe bytes after exit.
            loop {
                match stdout.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        output.extend_from_slice(&buf[..n]);
                        if output.len() > 65536 {
                            return Err("excessive output".into());
                        }
                    }
                    Err(_) => break,
                }
            }
            return if status.success() {
                Ok(output)
            } else {
                Err(format!("{program} failed: {status}"))
            };
        }
        if start.elapsed() > Duration::from_secs(2) {
            return Err(format!("{program} timed out"));
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}
fn nonblock(file: &impl std::os::fd::AsRawFd) -> Result<(), String> {
    let fd = file.as_raw_fd();
    // SAFETY: live descriptor; preserve its existing flags.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(())
}
struct ChildGuard(Child);
impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
struct Handle(u64);
impl Drop for Handle {
    fn drop(&mut self) {
        ml_session_close(self.0);
    }
}
#[derive(Clone, PartialEq)]
struct Monitor {
    name: String,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}
fn monitor(name: &str) -> Result<Monitor, String> {
    let value: serde_json::Value =
        serde_json::from_slice(&command("hyprctl", &["-j", "monitors"])?)
            .map_err(|e| e.to_string())?;
    let m = value
        .as_array()
        .ok_or("invalid monitors")?
        .iter()
        .find(|m| m["name"].as_str() == Some(name))
        .ok_or("output not found in active Hyprland monitors")?;
    let scale = m["scale"].as_f64().ok_or("missing scale")?;
    let mut width = m["width"].as_f64().ok_or("missing width")?;
    let mut height = m["height"].as_f64().ok_or("missing height")?;
    if m["transform"].as_u64().unwrap_or(0) % 2 == 1 {
        std::mem::swap(&mut width, &mut height);
    }
    if !scale.is_finite() || scale <= 0.0 || width < 16.0 || height < 16.0 {
        return Err("invalid monitor dimensions".into());
    }
    Ok(Monitor {
        name: name.into(),
        x: m["x"].as_f64().ok_or("missing x")?,
        y: m["y"].as_f64().ok_or("missing y")?,
        width: width / scale,
        height: height / scale,
    })
}
struct Options {
    address: String,
    output: String,
    bind: String,
    data: PathBuf,
    width: u32,
    height: u32,
    fps: u32,
    view_only: bool,
}
fn options() -> Result<Option<Options>, String> {
    let mut o = Options {
        address: String::new(),
        output: String::new(),
        bind: "0.0.0.0".into(),
        data: std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state")
            })
            .join("mooring"),
        width: 1280,
        height: 720,
        fps: 30,
        view_only: false,
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--help" || arg == "-h" {
            println!(
                "mooring-linux-host --address HOST_OR_IP --output eDP-1 [--bind IP] [--size 1280x720] [--fps 30] [--data-dir PATH] [--view-only]\nRun inside Hyprland. Pair a Mac using the displayed one-time code. TCP 45900. Ctrl+C stops sharing."
            );
            return Ok(None);
        }
        if arg == "--view-only" {
            o.view_only = true;
            continue;
        }
        let value = args
            .next()
            .ok_or_else(|| format!("missing value for {arg}"))?;
        match arg.as_str() {
            "--address" => o.address = value,
            "--output" => o.output = value,
            "--bind" => o.bind = value,
            "--data-dir" => o.data = value.into(),
            "--fps" => o.fps = value.parse().map_err(|_| "invalid fps")?,
            "--size" => {
                let (w, h) = value.split_once('x').ok_or("size must be WIDTHxHEIGHT")?;
                o.width = w.parse().map_err(|_| "invalid width")?;
                o.height = h.parse().map_err(|_| "invalid height")?;
            }
            _ => return Err(format!("unknown option: {arg}")),
        }
    }
    if o.address.is_empty() || o.output.is_empty() {
        return Err("--address and --output are required; see --help".into());
    }
    if !(1..=60).contains(&o.fps) {
        return Err("fps must be 1..60".into());
    }
    check(ml_video_dimensions_validate(o.width, o.height))?;
    Ok(Some(o))
}
fn identity(path: &Path) -> Result<Zeroizing<[u8; 96]>, String> {
    let mut bytes = Zeroizing::new([0; 96]);
    match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(mut file) => {
            let meta = file.metadata().map_err(|e| e.to_string())?;
            if !meta.is_file() || meta.len() != 96 || meta.permissions().mode() & 0o077 != 0 {
                return Err("identity must be an owner-only 96-byte file".into());
            }
            file.read_exact(&mut bytes[..]).map_err(|e| e.to_string())?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let (mut private, mut public, mut psk) = ([0; 32], [0; 32], [0; 32]);
            // SAFETY: three separate writable key arrays.
            check(unsafe {
                ml_session_generate_identity(
                    private.as_mut_ptr(),
                    public.as_mut_ptr(),
                    psk.as_mut_ptr(),
                )
            })?;
            bytes[..32].copy_from_slice(&private);
            bytes[32..64].copy_from_slice(&public);
            bytes[64..].copy_from_slice(&psk);
            use zeroize::Zeroize;
            private.zeroize();
            psk.zeroize();
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(path)
                .map_err(|e| e.to_string())?;
            file.write_all(&bytes[..])
                .and_then(|_| file.sync_all())
                .map_err(|e| e.to_string())?;
        }
        Err(e) => return Err(e.to_string()),
    }
    Ok(bytes)
}
struct Pipe(PathBuf);
impl Drop for Pipe {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}
fn stream(session: u64, o: &Options, expected_monitor: &Monitor) -> Result<(), String> {
    let pipe_path = o.data.join("capture.fifo");
    let path = cstr(pipe_path.to_str().ok_or("non-UTF8 data path")?)?;
    // SAFETY: NUL-terminated path, private directory; fail rather than use an existing entry.
    if unsafe { libc::mkfifo(path.as_ptr(), 0o600) } != 0 {
        return Err(format!(
            "capture FIFO: {} (remove a stale capture.fifo only with host stopped)",
            std::io::Error::last_os_error()
        ));
    }
    let pipe = Pipe(pipe_path);
    let mut reader = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(&pipe.0)
        .map_err(|e| e.to_string())?;
    let mut recorder = ChildGuard(
        Command::new("wf-recorder")
            .args([
                "-y",
                "-D",
                "--no-dmabuf",
                "-o",
                &o.output,
                "-r",
                &o.fps.to_string(),
                "-c",
                "libx264",
                "-x",
                "yuv420p",
                "-b",
                "0",
                "-p",
                "preset=ultrafast",
                "-p",
                "tune=zerolatency",
                "-p",
                &format!(
                    "x264-params=aud=1:repeat-headers=1:keyint={}:scenecut=0",
                    o.fps
                ),
                "-F",
                &format!("scale={}:{}", o.width, o.height),
                "-m",
                "h264",
                "-f",
                pipe.0.to_str().unwrap(),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|e| format!("wf-recorder: {e}"))?,
    );
    let mut parser = video::Parser::default();
    let mut buffer = [0; 65536];
    let mut last = Instant::now();
    let initial_monitor = monitor(&o.output)?;
    if &initial_monitor != expected_monitor {
        return Err("monitor layout changed; restart host".into());
    }
    let mut layout_check = Instant::now();
    while !STOP.load(Ordering::Relaxed) {
        match reader.read(&mut buffer) {
            Ok(n) if n > 0 => {
                last = Instant::now();
                for frame in parser.push(&buffer[..n])? {
                    frame.send(session, o.width, o.height)?;
                }
            }
            Ok(_) => std::thread::sleep(Duration::from_millis(5)),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(5))
            }
            Err(e) => return Err(e.to_string()),
        }
        if let Some(status) = recorder.0.try_wait().map_err(|e| e.to_string())? {
            return Err(format!("wf-recorder stopped: {status}"));
        }
        if last.elapsed() > Duration::from_secs(5) {
            return Err("capture stalled for five seconds".into());
        }
        if layout_check.elapsed() > Duration::from_secs(1) {
            let current = monitor(&o.output)?;
            if current != initial_monitor {
                return Err("monitor layout changed; restart sharing".into());
            }
            layout_check = Instant::now();
        }
        let mut queue = MLSendQueue::default();
        // SAFETY: live writable output. Also notices a receiver-side disconnect on a still screen.
        check(unsafe { ml_session_send_queue(session, &mut queue) })?;
    }
    Ok(())
}
fn receive(
    session: u64,
    m: Monitor,
    view_only: bool,
    size: (u32, u32),
    ready: std::sync::mpsc::SyncSender<()>,
) -> Result<(), String> {
    let mut input = if view_only {
        None
    } else {
        Some(input::Input::open()?)
    };
    // Allow the compositor to discover the new virtual input device before enabling input.
    if input.is_some() {
        std::thread::sleep(Duration::from_secs(1));
    }
    let geometry = MLControlMessage {
        kind: 1,
        input_enabled: input.is_some() as u8,
        geometry: MLDisplayGeometry {
            width: m.width,
            height: m.height,
            pixel_width: size.0,
            pixel_height: size.1,
            ..Default::default()
        },
        ..Default::default()
    };
    // SAFETY: message initialized and borrowed only during call.
    check(unsafe { ml_session_send_control(session, &geometry, 1000) })?;
    ready.send(()).map_err(|_| "capture startup cancelled")?;
    let mut buffer = vec![0; 12 * 1024 * 1024];
    loop {
        if STOP.load(Ordering::Relaxed) {
            return Ok(());
        }
        let mut message = MLSessionMessage::default();
        // SAFETY: receive buffer and message are live, correctly sized and exclusively borrowed.
        let status = unsafe {
            ml_session_receive(
                session,
                buffer.as_mut_ptr(),
                buffer.len(),
                &mut message,
                250,
            )
        };
        if status == -3 {
            continue;
        }
        check(status)?;
        match message.kind {
            2 => {
                if let Some(input) = input.as_mut() {
                    input.accept(&message.input, &m)?;
                }
            }
            3 if message.control.kind == 3 => {
                let reply = MLControlMessage {
                    kind: 4,
                    ping_id: message.control.ping_id,
                    ..Default::default()
                };
                // SAFETY: initialized control message.
                check(unsafe { ml_session_send_control(session, &reply, 1000) })?;
            }
            3 if message.control.kind == 13 => return Ok(()),
            _ => {} // Unsupported optional features are not advertised. Periodic IDRs handle recovery.
        }
    }
}
fn run() -> Result<(), String> {
    let Some(o) = options()? else { return Ok(()) };
    if !cfg!(target_os = "linux") {
        return Err("hosting requires Linux and an active Hyprland session".into());
    }
    if std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_none() {
        return Err("run this inside the logged-in Hyprland desktop".into());
    }
    let m = monitor(&o.output)?;
    fs::create_dir_all(&o.data).map_err(|e| e.to_string())?;
    let meta = fs::symlink_metadata(&o.data).map_err(|e| e.to_string())?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err("data directory must be a real directory".into());
    }
    fs::set_permissions(&o.data, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(o.data.join("host.lock"))
        .map_err(|e| e.to_string())?;
    lock.try_lock()
        .map_err(|_| "another Linux host is running")?;
    let keys = identity(&o.data.join("host.identity"))?;
    let directory = cstr(o.data.to_str().ok_or("non-UTF8 directory")?)?;
    let address = cstr(&o.address)?;
    let bind = cstr(&o.bind)?;
    let name = cstr("Omarchy")?;
    let mut listener = 0;
    ml_capabilities_set(512); // Only pairing revocation; no Apple-only display, gesture or codec promises.
    // SAFETY: key slices have 32 bytes; C strings live across synchronous calls.
    unsafe {
        check(ml_devices_init(directory.as_ptr(), 0))?;
        check(ml_session_listen_devices(
            bind.as_ptr(),
            45900,
            keys.as_ptr(),
            keys[64..].as_ptr(),
            directory.as_ptr(),
            &mut listener,
        ))?;
    }
    let listener = Handle(listener);
    let mut secret = Zeroizing::new([0; 32]);
    // SAFETY: all output buffers have the ABI sizes; code is fully initialized before encoding.
    unsafe {
        check(ml_listener_pairing_secret(listener.0, secret.as_mut_ptr()))?;
        let mut code = std::mem::zeroed::<MLPairingCode>();
        check(ml_pairing_code_for_host(
            address.as_ptr(),
            name.as_ptr(),
            keys[32..64].as_ptr(),
            secret.as_ptr(),
            2,
            std::ptr::null(),
            &mut code,
        ))?;
        let mut encoded = Zeroizing::new([0i8; ML_PAIRING_CODE_CAPACITY]);
        check(ml_pairing_code_encode(
            &code,
            encoded.as_mut_ptr(),
            encoded.len(),
        ))?;
        println!(
            "Sharing {} on TCP 45900. One-time pairing code (expires in 10 minutes):\n{}\nKeep this terminal private. Ctrl+C stops sharing.",
            m.name,
            CStr::from_ptr(encoded.as_ptr()).to_string_lossy()
        );
        use zeroize::Zeroize;
        code.secret.zeroize();
    }
    while !STOP.load(Ordering::Relaxed) {
        let mut session = 0;
        // SAFETY: listener is live, output is writable.
        let status = unsafe { ml_session_accept(listener.0, 500, &mut session) };
        if status == -3 {
            continue;
        }
        if status != 0 {
            eprintln!("Connection rejected: {}", check(status).unwrap_err());
            continue;
        }
        let session = Handle(session);
        if monitor(&o.output)? != m {
            return Err("monitor layout changed; restart host".into());
        }
        eprintln!("Authenticated viewer connected");
        std::thread::scope(|scope| {
            let id = session.0;
            let view_only = o.view_only;
            let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
            let monitor = m.clone();
            let size = (o.width, o.height);
            let receiver = scope.spawn(move || {
                let result = receive(id, monitor, view_only, size, ready_tx);
                ml_session_close(id);
                result
            });
            let result = match ready_rx.recv_timeout(Duration::from_secs(5)) {
                Ok(()) => stream(id, &o, &m),
                Err(_) => Err("input/geometry startup failed".into()),
            };
            ml_session_close(id);
            if let Err(e) = result {
                eprintln!("Stream ended: {e}");
            }
            match receiver.join() {
                Ok(Err(e)) => eprintln!("Control ended: {e}"),
                Err(_) => eprintln!("Control thread failed"),
                _ => {}
            }
        });
        eprintln!("Sharing stopped for this viewer; waiting for a paired Mac");
    }
    Ok(())
}
fn main() {
    // SAFETY: handlers only set an atomic flag; no allocation or IO.
    unsafe {
        libc::signal(libc::SIGINT, stop as *const () as usize);
        libc::signal(libc::SIGTERM, stop as *const () as usize);
    }
    if let Err(error) = run() {
        eprintln!("Mooring Linux host: {error}");
        std::process::exit(1);
    }
}
