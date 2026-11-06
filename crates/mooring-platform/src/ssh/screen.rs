//! A virtual screen on the Linux desktop, sized to the viewing Mac, for the
//! length of a session: the Linux counterpart of the Mac-to-Mac session's
//! virtual display.
//!
//! One `ssh -T` session runs a fixed script (`virtual-screen.sh`) that creates
//! a headless Hyprland output, moves the desktop's workspaces onto it and
//! points wayvnc at it, then holds while Mooring sends a heartbeat on its
//! input. Closing the input, or missing heartbeats for 20 seconds, makes the
//! remote side put everything back, so the laptop is restored even if
//! Mooring is killed or the network drops. The script travels base64-encoded
//! in the remote command, so the input carries only the heartbeat, and only
//! checked numbers are added to that command.

use super::{
    SpawnedSsh, SshFailure, SshFailureKind, SshOptions, SshRoute, TICK, base_args,
    failure_from_exit, spawn_ssh,
};
use serde::Serialize;
use std::ffi::OsString;
use std::io::{BufRead, BufReader, Read, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

pub const VIRTUAL_SCREEN_SCRIPT: &str = include_str!("virtual-screen.sh");
pub const VIRTUAL_SCREEN_READY_TIMEOUT: Duration = Duration::from_secs(20);
const HEARTBEAT: Duration = Duration::from_secs(5);
const RESTORE_TIMEOUT: Duration = Duration::from_secs(8);
const MAX_LINE_BYTES: usize = 512;
const MAX_LINES: usize = 64;

/// The virtual screen's size in pixels and its scale.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct ScreenSize {
    pub width: u32,
    pub height: u32,
    pub scale: u8,
}

impl ScreenSize {
    /// Parse `WIDTHxHEIGHT@SCALE`, such as `3024x1890@2`. Sizes are even,
    /// from 640x480 to 7680x4320, and the scale is 1 or 2, so the logical
    /// size is whole.
    pub fn parse(text: &str) -> Result<Self, String> {
        const USAGE: &str = "--screen must be WIDTHxHEIGHT@SCALE with even sizes from 640x480 to 7680x4320 and a scale of 1 or 2, for example 3024x1890@2.";
        let (size, scale) = text.split_once('@').ok_or(USAGE)?;
        let (width, height) = size.split_once('x').ok_or(USAGE)?;
        let number = |value: &str| -> Option<u32> {
            (!value.is_empty() && value.len() <= 5 && value.bytes().all(|b| b.is_ascii_digit()))
                .then(|| value.parse().ok())
                .flatten()
        };
        let (Some(width), Some(height)) = (number(width), number(height)) else {
            return Err(USAGE.into());
        };
        let scale = match scale {
            "1" => 1,
            "2" => 2,
            _ => return Err(USAGE.into()),
        };
        if !(640..=7680).contains(&width)
            || !(480..=4320).contains(&height)
            || width % 2 != 0
            || height % 2 != 0
        {
            return Err(USAGE.into());
        }
        Ok(Self {
            width,
            height,
            scale,
        })
    }
}

fn base64(data: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let bytes = [
            chunk[0],
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        let value = (u32::from(bytes[0]) << 16) | (u32::from(bytes[1]) << 8) | u32::from(bytes[2]);
        for index in 0..4 {
            if index <= chunk.len() {
                out.push(TABLE[((value >> (18 - 6 * index)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// The argv after the program name. The remote command is one string, as
/// ssh sends it: the base64 alphabet is safe in single quotes, and the size
/// is digits only.
pub fn virtual_screen_args(
    route: &SshRoute,
    options: &SshOptions,
    size: ScreenSize,
) -> Vec<OsString> {
    let mut args = base_args(options);
    for setting in ["RequestTTY=no", "RemoteCommand=none"] {
        args.push("-o".into());
        args.push(setting.into());
    }
    args.push("-T".into());
    args.push("--".into());
    args.push(route.target.clone().into());
    args.push(
        format!(
            "/bin/sh -c 'eval \"$(printf %s {} | base64 -d)\"' mooring {} {} {}",
            base64(VIRTUAL_SCREEN_SCRIPT.as_bytes()),
            size.width,
            size.height,
            size.scale
        )
        .into(),
    );
    args
}

/// A virtual screen that is in place on the remote desktop.
pub struct VirtualScreen {
    pub size: ScreenSize,
    pub name: String,
    /// The workspaces moved onto it, comma-separated, as the remote reported.
    pub workspaces: String,
    process: Arc<super::SshProcess>,
    stop: Arc<AtomicBool>,
    heartbeat: Option<JoinHandle<()>>,
    lines: mpsc::Receiver<String>,
    reader: Option<JoinHandle<()>>,
    stopped: bool,
}

fn explain(code: &str, target: &str) -> (SshFailureKind, String) {
    let message = match code {
        "in-use" => format!("Another viewer is already using a virtual screen on {target}."),
        "no-hyprland" => {
            format!("{target} isn’t running Hyprland, which Mooring needs to add a virtual screen.")
        }
        "no-wayvncctl" => format!(
            "wayvncctl isn’t installed on {target}, so wayvnc can’t be pointed at a virtual screen."
        ),
        "no-session" => format!("No one is signed in to a Wayland desktop on {target}."),
        "not-readable" => format!(
            "SSH signs in to {target} as a different user from the desktop’s, without root, so Mooring can’t change its screens."
        ),
        "mode-not-applied" => {
            format!("Hyprland on {target} did not apply the virtual screen’s size.")
        }
        "capture-failed" => format!("wayvnc on {target} did not switch to the virtual screen."),
        other => format!("Mooring couldn’t add a virtual screen on {target} ({other})."),
    };
    (SshFailureKind::Other, message)
}

/// Add the virtual screen and wait for it to be in place. Returns once the
/// remote side reports `ready`, fails, or `VIRTUAL_SCREEN_READY_TIMEOUT` (or
/// `should_stop`) ends the wait; on failure nothing is left on the remote.
pub fn start_virtual_screen(
    route: &SshRoute,
    options: &SshOptions,
    size: ScreenSize,
    should_stop: &dyn Fn() -> bool,
) -> Result<VirtualScreen, SshFailure> {
    start_with_timeout(
        route,
        options,
        size,
        VIRTUAL_SCREEN_READY_TIMEOUT,
        HEARTBEAT,
        should_stop,
    )
}

fn start_with_timeout(
    route: &SshRoute,
    options: &SshOptions,
    size: ScreenSize,
    timeout: Duration,
    heartbeat_every: Duration,
    should_stop: &dyn Fn() -> bool,
) -> Result<VirtualScreen, SshFailure> {
    let SpawnedSsh {
        process,
        stdin,
        stdout,
        stderr,
    } = spawn_ssh(virtual_screen_args(route, options, size), options)?;
    let (sender, lines) = mpsc::sync_channel::<String>(MAX_LINES);
    let reader = thread::Builder::new()
        .name("mooring-screen-output".into())
        .spawn(move || {
            let mut reader = BufReader::new(stdout);
            let mut line = Vec::new();
            loop {
                line.clear();
                match reader
                    .by_ref()
                    .take(MAX_LINE_BYTES as u64)
                    .read_until(b'\n', &mut line)
                {
                    Ok(0) | Err(_) => return,
                    Ok(_) => {
                        let text: String = String::from_utf8_lossy(&line)
                            .chars()
                            .filter(|c| !c.is_control())
                            .collect();
                        if sender.try_send(text).is_err() {
                            return;
                        }
                    }
                }
            }
        })
        .ok();
    let deadline = Instant::now() + timeout;
    let target = route.target.clone();
    // Errors the script reports are final; others are classified from ssh.
    let outcome: Result<String, (SshFailure, bool)> = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        match lines.recv_timeout(left.min(TICK)) {
            Ok(line) if line.starts_with("mooring-screen ready ") => break Ok(line),
            Ok(line) if line.starts_with("mooring-screen error ") => {
                let code = line["mooring-screen error ".len()..].trim().to_string();
                let (kind, message) = explain(&code, &target);
                break Err((SshFailure::new(kind, message), true));
            }
            Ok(_) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                break Err((
                    SshFailure::new(
                        SshFailureKind::Other,
                        format!("SSH to {target} ended before the virtual screen was in place."),
                    ),
                    false,
                ));
            }
            Err(mpsc::RecvTimeoutError::Timeout) if left.is_zero() => {
                break Err((
                    SshFailure::new(
                        SshFailureKind::TimedOut,
                        format!(
                            "The virtual screen on {target} was not ready within {} seconds.",
                            timeout.as_secs().max(1)
                        ),
                    ),
                    false,
                ));
            }
            Err(mpsc::RecvTimeoutError::Timeout) if should_stop() => {
                break Err((
                    SshFailure::new(
                        SshFailureKind::Other,
                        "Stopped before the virtual screen was in place.".into(),
                    ),
                    true,
                ));
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
    };
    match outcome {
        Ok(line) => {
            let mut parts = line["mooring-screen ready ".len()..].split_whitespace();
            let _size = parts.next();
            let name = parts.next().unwrap_or("MOORING-1").to_string();
            let workspaces = parts
                .next()
                .and_then(|w| w.strip_prefix("workspaces="))
                .unwrap_or("none")
                .to_string();
            let stop = Arc::new(AtomicBool::new(false));
            let beat_stop = Arc::clone(&stop);
            let heartbeat = thread::Builder::new()
                .name("mooring-screen-heartbeat".into())
                .spawn(move || {
                    let mut stdin = stdin;
                    let mut next = Instant::now() + heartbeat_every;
                    while !beat_stop.load(Ordering::SeqCst) {
                        if Instant::now() >= next {
                            if stdin.write_all(b"\n").and_then(|()| stdin.flush()).is_err() {
                                return;
                            }
                            next = Instant::now() + heartbeat_every;
                        }
                        thread::sleep(TICK);
                    }
                    // Dropping stdin here is the signal to restore.
                })
                .ok();
            drop(stderr);
            Ok(VirtualScreen {
                size,
                name,
                workspaces,
                process,
                stop,
                heartbeat,
                lines,
                reader,
                stopped: false,
            })
        }
        Err((error, final_answer)) => {
            // Closing input makes the remote side undo anything half done.
            drop(stdin);
            let status = process.finish(Duration::from_secs(5));
            if let Some(reader) = reader {
                let _ = reader.join();
            }
            let output = stderr.collect(Duration::from_millis(500));
            Err(if final_answer {
                error.with_output(Some(status), output)
            } else {
                failure_from_exit(route, Some(status), output, error)
            })
        }
    }
}

impl VirtualScreen {
    /// End the hold and wait, at most `RESTORE_TIMEOUT`, for the remote side to
    /// report that it put everything back. Returns whether it did.
    pub fn stop(mut self) -> bool {
        self.finish()
    }

    fn finish(&mut self) -> bool {
        if self.stopped {
            return true;
        }
        self.stopped = true;
        self.stop.store(true, Ordering::SeqCst);
        if let Some(heartbeat) = self.heartbeat.take() {
            let _ = heartbeat.join();
        }
        let deadline = Instant::now() + RESTORE_TIMEOUT;
        let mut restored = false;
        while Instant::now() < deadline {
            match self.lines.recv_timeout(TICK) {
                Ok(line) if line.trim() == "mooring-screen restored" => {
                    restored = true;
                    break;
                }
                Ok(_) | Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
        let _ = self.process.finish(Duration::from_secs(2));
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
        restored
    }
}

impl Drop for VirtualScreen {
    fn drop(&mut self) {
        self.finish();
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::{Fixture, fake_host_turn};
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::AtomicU64;

    fn route() -> SshRoute {
        SshRoute::new("m1-linux", "127.0.0.1", 5900).unwrap()
    }

    fn never() -> bool {
        false
    }

    #[test]
    fn sizes_are_checked() {
        assert_eq!(
            ScreenSize::parse("3024x1890@2").unwrap(),
            ScreenSize {
                width: 3024,
                height: 1890,
                scale: 2
            }
        );
        assert_eq!(ScreenSize::parse("1920x1080@1").unwrap().scale, 1);
        for bad in [
            "",
            "3024x1890",
            "3024x1890@3",
            "3024x1891@2",
            "100x100@1",
            "9000x4000@1",
            "3024x1890@2 ",
            "+3024x1890@2",
            "3024x-1890@2",
            "3024;id@2",
            "30240x1890@2",
        ] {
            assert!(ScreenSize::parse(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn base64_matches_the_standard_alphabet() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64(&[0xfb, 0xff]), "+/8=");
    }

    #[test]
    fn the_remote_command_carries_only_the_script_and_digits() {
        let size = ScreenSize::parse("3024x1890@2").unwrap();
        let args: Vec<String> = virtual_screen_args(&route(), &SshOptions::default(), size)
            .into_iter()
            .map(|a| a.into_string().unwrap())
            .collect();
        let target = args.iter().position(|a| a == "--").unwrap();
        assert_eq!(args[target + 1], "m1-linux");
        assert_eq!(args.len(), target + 3, "one remote command string");
        let command = &args[target + 2];
        assert!(command.starts_with("/bin/sh -c 'eval \"$(printf %s "));
        assert!(command.ends_with(" | base64 -d)\"' mooring 3024 1890 2"));
        let encoded = command.split_whitespace().nth(5).unwrap();
        assert!(
            encoded
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(&b))
        );
        assert!(args.contains(&"BatchMode=yes".to_string()) && args.contains(&"-T".to_string()));
    }

    /// Stand-ins for Hyprland, wayvnc and the session tools, keeping state in
    /// files, so the real script runs here under /bin/sh and dash.
    struct FakeDesktop {
        fixture: Fixture,
        runtime: PathBuf,
        /// Released last, after the fake host is cleaned up.
        _turn: std::sync::MutexGuard<'static, ()>,
    }

    impl FakeDesktop {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let turn = fake_host_turn();
            let fixture = Fixture::new("screen");
            let runtime = PathBuf::from(format!(
                "/tmp/mooring-vs-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let bin = fixture.0.join("bin");
            let state = fixture.0.join("state");
            fs::create_dir_all(&bin).unwrap();
            fs::create_dir_all(&state).unwrap();
            fs::write(state.join("monitors"), "eDP-1 2560x1600\n").unwrap();
            fs::write(state.join("workspaces"), "1 eDP-1\n3 eDP-1\n").unwrap();
            fs::write(state.join("capture"), "eDP-1\n").unwrap();
            fs::write(state.join("cursor"), "false\n").unwrap();
            let dir = fixture.0.display().to_string();
            let tool = |name: &str, body: &str| {
                let path = bin.join(name);
                fs::write(&path, format!("#!/bin/sh\nS='{dir}/state'\n{body}\n")).unwrap();
                fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
            };
            tool("id", "echo 0");
            tool("timeout", "[ \"$1\" = -k ] && shift 2\nshift\nexec \"$@\"");
            tool("runuser", "shift 3; exec \"$@\"");
            tool(
                "loginctl",
                r#"case "$1" in
  list-sessions) echo ' 6 1001 alex seat0 1023 user tty1 no -' ;;
  show-session)
    shift 2; value=; props=
    while [ $# -gt 0 ]; do case $1 in -p) props="$props $2"; shift 2 ;; --value) value=1; shift ;; *) shift ;; esac; done
    for p in $props; do
      case $p in Type) v=wayland ;; Active) v=yes ;; User) v=1001 ;; Name) v=alex ;; *) v= ;; esac
      if [ -n "$value" ]; then echo "$v"; else echo "$p=$v"; fi
    done ;;
esac"#,
            );
            tool(
                "hyprctl",
                r#"echo "hyprctl $*" >> "$S/log"
case "$1 $2" in
  "monitors all") while read -r name size; do printf 'Monitor %s (ID 0):\n\t%s@60.00000 at 0x0\n\tfocused: yes\n\n' "$name" "$size"; done < "$S/monitors" ;;
  "workspaces "*) while read -r id mon; do printf 'workspace %s (%s) on monitor %s:\n\tmonitorID: 0\n\twindows: 1\n\n' "$id" "$id" "$mon"; done < "$S/workspaces" ;;
  "output create") echo "$4 1920x1080" >> "$S/monitors"; echo ok ;;
  "output remove") grep -v "^$3 " "$S/monitors" > "$S/m"; mv "$S/m" "$S/monitors"; sed "s/ $3\$/ eDP-1/" "$S/workspaces" > "$S/w"; mv "$S/w" "$S/workspaces"; echo ok ;;
  "-j getoption") printf '{"option": "%s", "bool": %s, "set": true }\n' "$3" "$(cat "$S/cursor")" ;;
  "eval hl.config"*) case "$2" in *"invisible = true"*) echo true > "$S/cursor" ;; *"invisible = false"*) echo false > "$S/cursor" ;; esac; echo ok ;;
  "eval "*) mode=$(echo "$2" | sed -n 's/.*mode = "\([0-9]*x[0-9]*\)@60".*/\1/p'); out=$(echo "$2" | sed -n 's/.*output = "\([^"]*\)".*/\1/p'); sed "s/^$out .*/$out $mode/" "$S/monitors" > "$S/m"; mv "$S/m" "$S/monitors"; echo ok ;;
  "dispatch "*)
    case "$2" in
      *focus*) echo "$2" | sed -n 's/.*workspace = "\([0-9]*\)".*/\1/p' > "$S/focused" ;;
      *workspace.move*) ws=$(cat "$S/focused"); mon=$(echo "$2" | sed -n 's/.*monitor = "\([^"]*\)".*/\1/p'); sed "s/^$ws .*/$ws $mon/" "$S/workspaces" > "$S/w"; mv "$S/w" "$S/workspaces" ;;
    esac; echo ok ;;
esac"#,
            );
            tool(
                "wayvncctl",
                r#"echo "wayvncctl $*" >> "$S/log"
case "$1" in
  output-list) cur=$(cat "$S/capture"); while read -r name size; do [ "$name" = "$cur" ] && m='*' || m=' '; echo "$m $name: \"\" ($size)"; done < "$S/monitors" ;;
  output-set) echo "$2" > "$S/capture" ;;
esac"#,
            );
            let hypr = runtime.join("1001/hypr/sig");
            fs::create_dir_all(&hypr).unwrap();
            drop(UnixListener::bind(hypr.join(".socket.sock")).unwrap());
            Self {
                fixture,
                runtime,
                _turn: turn,
            }
        }

        /// A fake ssh that runs the remote command string under `shell`.
        fn ssh(&self, shell: &str) -> SshOptions {
            let dir = self.fixture.0.display();
            self.fixture.fake_ssh(&format!(
                "for last; do :; done\nPATH='{dir}/bin':$PATH MOORING_RUNTIME_ROOT='{}' exec {shell} -c \"$last\"",
                self.runtime.display()
            ))
        }

        fn state(&self, name: &str) -> String {
            fs::read_to_string(self.fixture.0.join("state").join(name)).unwrap_or_default()
        }

        fn log(&self) -> String {
            self.state("log")
        }
    }

    impl Drop for FakeDesktop {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.runtime);
        }
    }

    fn shells() -> Vec<&'static str> {
        ["/bin/sh", "/bin/dash"]
            .into_iter()
            .filter(|shell| Path::new(shell).exists())
            .collect()
    }

    #[test]
    fn the_desktop_moves_to_the_virtual_screen_and_back() {
        for shell in shells() {
            let desktop = FakeDesktop::new();
            let size = ScreenSize::parse("3024x1890@2").unwrap();
            let screen = start_virtual_screen(&route(), &desktop.ssh(shell), size, &never)
                .unwrap_or_else(|e| panic!("{shell}: {e:?} log: {}", desktop.log()));
            assert_eq!(
                (screen.name.as_str(), screen.workspaces.as_str()),
                ("MOORING-1", "1,3"),
                "{shell}"
            );
            assert!(
                desktop.state("monitors").contains("MOORING-1 3024x1890"),
                "{shell}"
            );
            assert_eq!(
                desktop.state("workspaces"),
                "1 MOORING-1\n3 MOORING-1\n",
                "{shell}"
            );
            assert_eq!(desktop.state("capture").trim(), "MOORING-1", "{shell}");
            assert!(desktop.log().contains("scale = 2"), "{shell}");
            assert_eq!(
                desktop.state("cursor").trim(),
                "true",
                "{shell}: Hyprland's pointer hidden"
            );
            let cursor_file = desktop.runtime.join("1001/mooring-virtual-screen.cursor");
            assert!(cursor_file.exists(), "{shell}");
            assert!(
                screen.stop(),
                "{shell}: not restored; log: {}",
                desktop.log()
            );
            assert_eq!(desktop.state("monitors"), "eDP-1 2560x1600\n", "{shell}");
            assert_eq!(desktop.state("workspaces"), "1 eDP-1\n3 eDP-1\n", "{shell}");
            assert_eq!(desktop.state("capture").trim(), "eDP-1", "{shell}");
            assert_eq!(
                desktop.state("focused").trim(),
                "1",
                "{shell}: first workspace focused again"
            );
            assert_eq!(
                desktop.state("cursor").trim(),
                "false",
                "{shell}: pointer shown again"
            );
            assert!(!cursor_file.exists(), "{shell}");
            desktop.fixture.assert_no_survivors();
        }
    }

    #[test]
    fn a_pointer_hidden_by_the_person_stays_hidden_and_a_stale_hide_is_undone() {
        let size = ScreenSize::parse("1920x1200@1").unwrap();
        // Hidden in the desktop's own settings: left alone, then and after.
        let desktop = FakeDesktop::new();
        fs::write(desktop.fixture.0.join("state/cursor"), "true\n").unwrap();
        let screen = start_virtual_screen(&route(), &desktop.ssh("/bin/sh"), size, &never).unwrap();
        assert!(screen.stop());
        assert_eq!(desktop.state("cursor").trim(), "true");
        assert!(!desktop.log().contains("hl.config"), "{}", desktop.log());
        drop(desktop);
        // Hidden by a session that could not restore it: shown again first.
        let desktop = FakeDesktop::new();
        fs::write(desktop.fixture.0.join("state/cursor"), "true\n").unwrap();
        fs::write(
            desktop.runtime.join("1001/mooring-virtual-screen.cursor"),
            "hidden\n",
        )
        .unwrap();
        let screen = start_virtual_screen(&route(), &desktop.ssh("/bin/sh"), size, &never).unwrap();
        assert_eq!(
            desktop.state("cursor").trim(),
            "true",
            "hidden for this session"
        );
        assert!(screen.stop());
        assert_eq!(desktop.state("cursor").trim(), "false");
        assert!(
            !desktop
                .runtime
                .join("1001/mooring-virtual-screen.cursor")
                .exists()
        );
    }

    #[test]
    fn heartbeats_keep_the_screen_in_place_until_stop() {
        let desktop = FakeDesktop::new();
        let size = ScreenSize::parse("1920x1200@1").unwrap();
        let screen = start_with_timeout(
            &route(),
            &desktop.ssh("/bin/sh"),
            size,
            Duration::from_secs(10),
            Duration::from_millis(50),
            &never,
        )
        .unwrap();
        // Several heartbeats arrive; each one keeps the hold going.
        thread::sleep(Duration::from_millis(400));
        assert_eq!(desktop.state("capture").trim(), "MOORING-1");
        assert!(desktop.state("monitors").contains("MOORING-1 1920x1200"));
        assert!(screen.stop());
        assert_eq!(desktop.state("capture").trim(), "eDP-1");
        desktop.fixture.assert_no_survivors();
    }

    #[test]
    fn a_screen_in_use_is_left_alone_and_a_stale_one_is_replaced() {
        let desktop = FakeDesktop::new();
        // Another live session holds it.
        fs::write(
            desktop.runtime.join("1001/mooring-virtual-screen.pid"),
            format!("{}\n", std::process::id()),
        )
        .unwrap();
        let size = ScreenSize::parse("1920x1200@1").unwrap();
        let error = start_virtual_screen(&route(), &desktop.ssh("/bin/sh"), size, &never)
            .err()
            .unwrap();
        assert!(
            error.message.contains("Another viewer"),
            "{}",
            error.message
        );
        assert!(
            !desktop.log().contains("output create"),
            "{}",
            desktop.log()
        );
        assert_eq!(desktop.state("capture").trim(), "eDP-1");
        // A stale one from a session that could not clean up.
        fs::remove_file(desktop.runtime.join("1001/mooring-virtual-screen.pid")).unwrap();
        fs::write(
            desktop.fixture.0.join("state/monitors"),
            "eDP-1 2560x1600\nMOORING-1 800x600\n",
        )
        .unwrap();
        let screen = start_virtual_screen(&route(), &desktop.ssh("/bin/sh"), size, &never).unwrap();
        assert!(desktop.state("monitors").contains("MOORING-1 1920x1200"));
        assert!(screen.stop());
    }

    #[test]
    fn failures_leave_nothing_behind() {
        let desktop = FakeDesktop::new();
        // wayvncctl missing: refused before anything is created.
        fs::remove_file(desktop.fixture.0.join("bin/wayvncctl")).unwrap();
        let size = ScreenSize::parse("1920x1200@1").unwrap();
        let error = start_virtual_screen(&route(), &desktop.ssh("/bin/sh"), size, &never)
            .err()
            .unwrap();
        assert!(error.message.contains("wayvncctl"), "{}", error.message);
        assert_eq!(desktop.state("monitors"), "eDP-1 2560x1600\n");
        // ssh itself failing is classified like any other ssh failure.
        let fixture = Fixture::new("screen-denied");
        let denied =
            fixture.fake_ssh("echo 'm1-linux: Permission denied (publickey).' >&2; exit 255");
        let error = start_virtual_screen(&route(), &denied, size, &never)
            .err()
            .unwrap();
        assert_eq!(error.kind, SshFailureKind::AuthenticationFailed);
        fixture.assert_no_survivors();
    }
}
