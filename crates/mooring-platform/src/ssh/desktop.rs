//! Read whether the remote desktop is locked, over the same SSH as the tunnel.
//!
//! One short `ssh -T` session feeds a fixed, read-only script
//! (`desktop-probe.sh`, compiled into Mooring) to the remote `/bin/sh -s`.
//! Nothing from a saved connection or the remote host is inserted into the
//! script. Its output is interpreted by [`mooring_core::desktop`]. SSH runs
//! with the same key-only, no-prompt options as the tunnel, so a check can
//! never ask the remote PAM stack about a password.

use super::{
    SpawnedSsh, SshFailure, SshFailureKind, SshOptions, SshRoute, TICK, base_args,
    failure_from_exit, now_ms, spawn_ssh, wait_until,
};
use mooring_core::desktop::{
    DesktopStatus, DesktopWatch, DesktopWatchLimits, MAX_PROBE_OUTPUT_BYTES, PROBE_MARKER,
    WatchFailure, parse_probe,
};
use serde::Serialize;
use std::ffi::OsString;
use std::io::{Read, Write};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

/// The remote half of the desktop check. Read-only.
pub const DESKTOP_PROBE_SCRIPT: &str = include_str!("desktop-probe.sh");
/// Bound for one check, including ssh's own connection and key sign-in.
pub const DESKTOP_PROBE_TIMEOUT: Duration = Duration::from_secs(15);

/// The argv after the program name: no terminal, no configured
/// `RemoteCommand`, the destination after `--`, then the fixed command.
pub fn desktop_probe_args(route: &SshRoute, options: &SshOptions) -> Vec<OsString> {
    let mut args = base_args(options);
    for setting in ["RequestTTY=no", "RemoteCommand=none"] {
        args.push("-o".into());
        args.push(setting.into());
    }
    args.push("-T".into());
    args.push("--".into());
    args.push(route.target.clone().into());
    args.push("/bin/sh".into());
    args.push("-s".into());
    args
}

/// Run the desktop check once. `timeout` bounds the whole check; ssh is
/// always stopped and reaped before this returns.
pub fn probe_desktop(
    route: &SshRoute,
    options: &SshOptions,
    timeout: Duration,
    should_stop: &dyn Fn() -> bool,
) -> Result<DesktopStatus, SshFailure> {
    let started = Instant::now();
    let SpawnedSsh {
        process,
        stdin,
        stdout,
        stderr,
    } = spawn_ssh(desktop_probe_args(route, options), options)?;
    let (sender, receiver) = mpsc::sync_channel(1);
    let conversation = thread::Builder::new()
        .name("mooring-desktop-probe".into())
        .spawn(move || {
            let mut stdin = stdin;
            // A failed write means ssh has already exited; its stderr says why.
            let _ = stdin.write_all(DESKTOP_PROBE_SCRIPT.as_bytes());
            drop(stdin);
            let mut output = Vec::new();
            let _ = stdout
                .take(MAX_PROBE_OUTPUT_BYTES as u64)
                .read_to_end(&mut output);
            let _ = sender.send(output);
        });
    let deadline = started + timeout;
    let mut stopped = false;
    let outcome = match &conversation {
        Ok(_) => loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match receiver.recv_timeout(left.min(TICK)) {
                Ok(output) => break Some(output),
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
    let grace = if outcome.is_some() {
        Duration::from_millis(1500)
    } else {
        Duration::ZERO
    };
    let status = Some(process.finish(grace));
    if let Ok(handle) = conversation {
        let _ = handle.join();
    }
    let lines = stderr.collect(Duration::from_millis(500));
    let target = &route.target;
    match outcome {
        // ssh's own messages are classified only when the script never ran:
        // once it has, anything on stderr came from the remote commands.
        Some(output) if contains_marker(&output) => parse_probe(&output).map_err(|message| {
            SshFailure::new(SshFailureKind::Other, format!("{message} ({target})"))
                .with_output(status, lines)
        }),
        Some(_) => Err(failure_from_exit(
            route,
            status,
            lines,
            SshFailure::new(
                SshFailureKind::Other,
                format!(
                    "SSH reached {target}, but it could not run Mooring’s read-only desktop check there (it needs /bin/sh)."
                ),
            ),
        )),
        None if stopped => Err(SshFailure::new(
            SshFailureKind::Other,
            "Stopped before the desktop check finished.".into(),
        )
        .with_output(status, lines)),
        None => Err(failure_from_exit(
            route,
            status,
            lines,
            SshFailure::new(
                SshFailureKind::TimedOut,
                format!(
                    "The desktop check on {target} did not finish within {} seconds.",
                    timeout.as_secs().max(1)
                ),
            ),
        )),
    }
}

fn contains_marker(output: &[u8]) -> bool {
    output
        .split(|byte| *byte == b'\n')
        .any(|line| line.strip_suffix(b"\r").unwrap_or(line) == PROBE_MARKER.as_bytes())
}

/// Desktop reports while a session is open. Serialized as JSON lines.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum DesktopEvent {
    /// The first reading, and each reading that differs from the last.
    Desktop(DesktopStatus),
    /// A check failed. `retrying` is false once Mooring has stopped checking.
    DesktopUnavailable { error: SshFailure, retrying: bool },
}

/// Check the desktop now, then again on the schedule from
/// [`DesktopWatch`], until `should_stop` returns true or the watch ends.
/// At most one check runs at a time, and each is bounded by `probe_timeout`.
pub fn watch_desktop(
    route: &SshRoute,
    options: &SshOptions,
    limits: DesktopWatchLimits,
    probe_timeout: Duration,
    should_stop: &dyn Fn() -> bool,
    report: &mut dyn FnMut(&DesktopEvent),
) -> Result<(), String> {
    let start = Instant::now();
    let mut watch = DesktopWatch::new(limits, 0)?;
    while let Some(due_ms) = watch.next_due_ms() {
        if !wait_until(start + Duration::from_millis(due_ms), should_stop) {
            break;
        }
        match probe_desktop(route, options, probe_timeout, should_stop) {
            Ok(status) => {
                if watch.record_status(now_ms(start), &status) {
                    report(&DesktopEvent::Desktop(status));
                }
            }
            Err(_) if should_stop() => break,
            Err(error) => match watch.record_failure(now_ms(start)) {
                WatchFailure::Report => report(&DesktopEvent::DesktopUnavailable {
                    error,
                    retrying: true,
                }),
                WatchFailure::Quiet => {}
                WatchFailure::Stop => report(&DesktopEvent::DesktopUnavailable {
                    error,
                    retrying: false,
                }),
            },
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::tests::{Fixture, fake_host_turn};
    use super::*;
    use mooring_core::desktop::{DisplayState, LockEvidence, LockState, SessionState};
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

    fn route() -> SshRoute {
        SshRoute::new("m1-linux", "127.0.0.1", 5900).unwrap()
    }

    fn never() -> bool {
        false
    }

    /// Stand-ins for the Linux commands the probe reads, so the real script
    /// runs here under `/bin/sh` exactly as it would on the remote host.
    struct FakeLinux {
        fixture: Fixture,
        /// Short, because a Unix socket path is limited to about 100 bytes.
        runtime: PathBuf,
        /// Released last, after the fake host is cleaned up.
        _turn: std::sync::MutexGuard<'static, ()>,
    }

    impl FakeLinux {
        fn new(uid: u32, omarchy_lock: Option<&str>) -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let turn = fake_host_turn();
            let fixture = Fixture::new("desktop");
            let runtime = PathBuf::from(format!(
                "/tmp/mooring-rt-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let bin = fixture.0.join("bin");
            fs::create_dir_all(&bin).unwrap();
            let dir = fixture.0.display().to_string();
            let tool = |name: &str, body: String| {
                let path = bin.join(name);
                fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
                fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
            };
            tool("id", format!("echo {uid}"));
            tool("timeout", "shift 3; exec \"$@\"".into());
            tool(
                "runuser",
                format!("echo \"$2\" >> '{dir}/runuser'; shift 3; exec \"$@\""),
            );
            tool(
                "loginctl",
                r#"case "$1" in
  list-sessions) printf '24 1002 ci - 91814 manager - no -\n 6 1001 alex seat0 1023 user tty1 no -\n' ;;
  show-session)
    sid=$2; shift 2; props=; value=
    while [ $# -gt 0 ]; do case $1 in -p) props="$props $2"; shift 2 ;; --value) value=1; shift ;; *) shift ;; esac; done
    for p in $props; do
      case "$sid:$p" in
        6:Id) v=6 ;; 6:Type) v=wayland ;; 6:Active) v=yes ;; 6:Name) v=alex ;;
        6:User) v=1001 ;; 6:LockedHint) v=no ;; 24:Type) v=unspecified ;; *) v= ;;
      esac
      if [ -n "$value" ]; then echo "$v"; else echo "$p=$v"; fi
    done ;;
esac"#
                    .into(),
            );
            tool(
                "hyprctl",
                format!(
                    r#"[ "$HYPRLAND_INSTANCE_SIGNATURE" = sig ] && [ "$XDG_RUNTIME_DIR" = '{}/1001' ] || exit 1
case "$2" in
  monitors) printf '[{{\n  "name": "eDP-1",\n  "dpmsStatus": false,\n  "disabled": false,\n  "solitaryBlockedBy": ["LOCK", "WINDOWED"]\n}}]\n' ;;
  getoption) printf '{{\n "option": "%s",\n "bool": true, "set": true }}\n' "$3" ;;
esac"#,
                    runtime.display()
                ),
            );
            if let Some(status) = omarchy_lock {
                let root = fixture.0.join("omarchy/shell");
                fs::create_dir_all(&root).unwrap();
                fs::write(root.join("shell.qml"), "").unwrap();
                // qs prints a locale warning on stdout before the answer.
                tool(
                    "omarchy-shell",
                    format!(
                        "[ \"$1 $2\" = 'lock status' ] || exit 1\necho 'WARN: Detected locale \"C\"'\necho '{status}'"
                    ),
                );
            }
            let hypr = runtime.join("1001/hypr/sig");
            fs::create_dir_all(&hypr).unwrap();
            let socket = hypr.join(".socket.sock");
            assert!(socket.as_os_str().len() < 100, "{}", socket.display());
            drop(UnixListener::bind(&socket).unwrap());
            Self {
                fixture,
                runtime,
                _turn: turn,
            }
        }

        /// A fake ssh that runs the script it is given under `shell` here.
        fn ssh(&self, shell: &str) -> SshOptions {
            let dir = self.fixture.0.display();
            self.fixture.fake_ssh(&format!(
                "PATH='{dir}/bin':$PATH MOORING_RUNTIME_ROOT='{}' MOORING_OMARCHY_ROOT='{dir}/omarchy' exec {shell} -s",
                self.runtime.display()
            ))
        }

        fn runuser_calls(&self) -> Vec<String> {
            fs::read_to_string(self.fixture.0.join("runuser"))
                .unwrap_or_default()
                .lines()
                .map(str::to_owned)
                .collect()
        }

        fn args(&self) -> Vec<String> {
            read_args(&self.fixture.0)
        }
    }

    impl Drop for FakeLinux {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.runtime);
        }
    }

    fn read_args(dir: &Path) -> Vec<String> {
        fs::read_to_string(dir.join("args"))
            .unwrap()
            .lines()
            .map(str::to_owned)
            .collect()
    }

    /// Remote hosts' /bin/sh may be bash or dash, so the script must be POSIX.
    /// macOS ships both.
    fn shells() -> Vec<&'static str> {
        ["/bin/sh", "/bin/dash"]
            .into_iter()
            .filter(|shell| Path::new(shell).exists())
            .collect()
    }

    const OMARCHY_LOCKED: &str = r#"{"locked":true,"requested":true,"pending":false,"sessionLocked":true,"secure":true,"authenticating":false}"#;

    #[test]
    fn the_argv_runs_a_fixed_command_without_a_terminal_or_forward() {
        let options = SshOptions {
            config_file: Some(PathBuf::from("/tmp/isolated config")),
            ..SshOptions::default()
        };
        let args: Vec<String> = desktop_probe_args(&route(), &options)
            .into_iter()
            .map(|a| a.into_string().unwrap())
            .collect();
        assert_eq!(&args[..2], ["-F", "/tmp/isolated config"]);
        assert_eq!(&args[args.len() - 4..], ["--", "m1-linux", "/bin/sh", "-s"]);
        for expected in [
            "BatchMode=yes",
            "PasswordAuthentication=no",
            "KbdInteractiveAuthentication=no",
            "RequestTTY=no",
            "RemoteCommand=none",
            "ControlMaster=no",
        ] {
            assert!(args.iter().any(|a| a == expected), "{expected} missing");
        }
        assert!(args.contains(&"-T".to_string()));
        assert!(!args.contains(&"-W".to_string()));
        // The script is constant: nothing from the route appears in it.
        assert!(!DESKTOP_PROBE_SCRIPT.contains("m1-linux"));
        assert!(DESKTOP_PROBE_SCRIPT.contains(PROBE_MARKER));
    }

    #[test]
    fn the_real_script_reads_a_locked_hyprland_session_as_root() {
        for shell in shells() {
            reads_a_locked_hyprland_session_as_root(shell);
        }
    }

    fn reads_a_locked_hyprland_session_as_root(shell: &str) {
        let host = FakeLinux::new(0, Some(OMARCHY_LOCKED));
        let options = host.ssh(shell);
        let status = probe_desktop(&route(), &options, Duration::from_secs(10), &never)
            .unwrap_or_else(|error| panic!("{shell}: {error:?}"));
        assert_eq!(status.lock, LockState::Locked);
        assert_eq!(status.display, DisplayState::Off);
        assert_eq!(status.session, SessionState::Found);
        assert_eq!(status.evidence, LockEvidence::HyprlandSessionLock);
        assert_eq!(status.session_user.as_deref(), Some("alex"));
        assert_eq!(status.lock_screen.as_deref(), Some("omarchy"));
        assert_eq!(status.input_wakes_display, Some(true));
        assert!(status.notes.is_empty(), "{:?}", status.notes);
        // As root, every query ran as the session's user, never as root.
        let calls = host.runuser_calls();
        assert!(
            !calls.is_empty() && calls.iter().all(|user| user == "alex"),
            "{calls:?}"
        );
        assert_eq!(&host.args()[host.args().len() - 2..], ["/bin/sh", "-s"]);
        host.fixture.assert_no_survivors();
    }

    #[test]
    fn the_real_script_reads_its_own_session_without_runuser() {
        for shell in shells() {
            let host = FakeLinux::new(1001, None);
            let status = probe_desktop(&route(), &host.ssh(shell), Duration::from_secs(10), &never)
                .unwrap_or_else(|error| panic!("{shell}: {error:?}"));
            assert_eq!(
                (status.lock, status.lock_screen.as_deref()),
                (LockState::Locked, None),
                "{shell}"
            );
            assert!(host.runuser_calls().is_empty());
        }
    }

    #[test]
    fn another_user_cannot_read_the_session() {
        for shell in shells() {
            let host = FakeLinux::new(1002, Some(OMARCHY_LOCKED));
            let status = probe_desktop(&route(), &host.ssh(shell), Duration::from_secs(10), &never)
                .unwrap_or_else(|error| panic!("{shell}: {error:?}"));
            assert_eq!(status.session, SessionState::NotReadable, "{shell}");
            assert_eq!(status.lock, LockState::Unknown);
            assert!(host.runuser_calls().is_empty());
        }
    }

    #[test]
    fn ssh_failures_are_classified_and_bounded() {
        let fixture = Fixture::new("desktop-fail");
        let denied = fixture.fake_ssh(
            "cat >/dev/null; echo 'root@m1-linux: Permission denied (publickey).' >&2; exit 255",
        );
        let error = probe_desktop(&route(), &denied, Duration::from_secs(5), &never).unwrap_err();
        assert_eq!(error.kind, SshFailureKind::AuthenticationFailed);
        // No /bin/sh, or a shell that refuses commands.
        let no_shell = fixture.fake_ssh("cat >/dev/null; echo 'sh: not found' >&2; exit 127");
        let error = probe_desktop(&route(), &no_shell, Duration::from_secs(5), &never).unwrap_err();
        assert_eq!(error.kind, SshFailureKind::Other);
        assert!(error.message.contains("/bin/sh"), "{}", error.message);
        assert_eq!(error.ssh_exit_code, Some(127));
        // A report cut short is an error, never "unlocked".
        let cut = fixture.fake_ssh(&format!(
            "cat >/dev/null; echo '{PROBE_MARKER}'; echo 'session.Name=alex'"
        ));
        let error = probe_desktop(&route(), &cut, Duration::from_secs(5), &never).unwrap_err();
        assert!(
            error.message.contains("before it finished"),
            "{}",
            error.message
        );
        // Remote stderr after the marker is not mistaken for an ssh failure.
        let noisy = fixture.fake_ssh(&format!(
            "cat >/dev/null; echo 'ls: Permission denied' >&2; printf '{PROBE_MARKER}\\nsession=none\\nend\\n'"
        ));
        let status = probe_desktop(&route(), &noisy, Duration::from_secs(5), &never).unwrap();
        assert_eq!(status.session, SessionState::NoSession);
        fixture.assert_no_survivors();
    }

    #[test]
    fn a_hung_check_is_stopped_at_its_deadline_or_on_request() {
        let fixture = Fixture::new("desktop-hang");
        let options = fixture.fake_ssh("trap '' TERM\nwhile :; do sleep 1; done");
        let started = Instant::now();
        let error =
            probe_desktop(&route(), &options, Duration::from_millis(300), &never).unwrap_err();
        assert_eq!(error.kind, SshFailureKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(3));
        let started = Instant::now();
        let stop = || started.elapsed() > Duration::from_millis(200);
        let error = probe_desktop(&route(), &options, Duration::from_secs(30), &stop).unwrap_err();
        assert!(error.message.contains("Stopped"), "{}", error.message);
        assert!(started.elapsed() < Duration::from_secs(3));
        fixture.assert_no_survivors();
    }

    fn quick_limits() -> DesktopWatchLimits {
        DesktopWatchLimits {
            locked_interval_ms: 1_000,
            unlocked_interval_ms: 1_000,
            unknown_interval_ms: 1_000,
            failure_interval_ms: 1_000,
            max_consecutive_failures: 2,
        }
    }

    #[test]
    fn watching_reports_changes_until_stopped() {
        let fixture = Fixture::new("desktop-watch");
        let dir = fixture.0.display();
        // Locked for two checks, then unlocked.
        let options = fixture.fake_ssh(&format!(
            r#"cat >/dev/null
n=$(cat '{dir}/count' 2>/dev/null || echo 0); n=$((n + 1)); echo $n > '{dir}/count'
if [ $n -le 2 ]; then reasons='["LOCK"]'; else reasons='["WINDOWED"]'; fi
printf '{PROBE_MARKER}\nhyprland.monitors=[{{"dpmsStatus":true,"solitaryBlockedBy":%s}}]\nend\n' "$reasons""#
        ));
        let mut events = Vec::new();
        let done = AtomicBool::new(false);
        let started = Instant::now();
        watch_desktop(
            &route(),
            &options,
            quick_limits(),
            Duration::from_secs(5),
            &|| done.load(Ordering::SeqCst) || started.elapsed() > Duration::from_secs(10),
            &mut |event| {
                events.push(serde_json::to_value(event).unwrap());
                if events.len() == 2 {
                    done.store(true, Ordering::SeqCst);
                }
            },
        )
        .unwrap();
        let locks: Vec<_> = events
            .iter()
            .map(|e| (e["event"].clone(), e["lock"].clone()))
            .collect();
        assert_eq!(
            locks,
            [
                ("desktop".into(), "locked".into()),
                ("desktop".into(), "unlocked".into())
            ]
        );
        // The second locked reading was not repeated.
        let checks: u32 = fs::read_to_string(fixture.0.join("count"))
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert_eq!(checks, 3);
        assert!(started.elapsed() < Duration::from_secs(5));
        fixture.assert_no_survivors();
    }

    #[test]
    fn watching_gives_up_after_its_failure_budget() {
        let fixture = Fixture::new("desktop-watch-fail");
        let options = fixture.fake_ssh(
            "cat >/dev/null; echo 'm1-linux: Permission denied (publickey).' >&2; exit 255",
        );
        let mut events = Vec::new();
        watch_desktop(
            &route(),
            &options,
            quick_limits(),
            Duration::from_secs(5),
            &never,
            &mut |event| events.push(serde_json::to_value(event).unwrap()),
        )
        .unwrap();
        assert_eq!(events.len(), 2, "{events:?}");
        assert_eq!(events[0]["event"], "desktop_unavailable");
        assert_eq!(events[0]["retrying"], true);
        assert_eq!(events[0]["error"]["kind"], "authentication_failed");
        assert_eq!(events[1]["retrying"], false);
        assert_eq!(fixture.pids().len(), 2);
        fixture.assert_no_survivors();
        let invalid = DesktopWatchLimits {
            locked_interval_ms: 0,
            ..quick_limits()
        };
        assert!(
            watch_desktop(
                &route(),
                &options,
                invalid,
                Duration::from_secs(1),
                &never,
                &mut |_| {}
            )
            .is_err()
        );
    }
}
