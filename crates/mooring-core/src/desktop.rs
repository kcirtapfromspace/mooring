//! Whether a remote Linux desktop is locked and whether its display is on.
//!
//! Mooring reads this over SSH with a fixed, read-only probe; this module only
//! interprets the probe's output and decides when to read it again. Nothing
//! here unlocks a screen or handles a password. When a desktop is locked, the
//! person signs in on its lock screen through the viewer.
//!
//! Evidence, strongest first:
//! - Hyprland's monitors: an active ext-session-lock shows as `LOCK` among
//!   a monitor's `solitaryBlockedBy` reasons, whichever program locked it.
//! - The Omarchy lock screen's own status.
//! - logind's `LockedHint`. Many lock screens never set it, so "not locked"
//!   from logind alone is trusted only for desktops known to set it.
//!
//! This is pure code: it starts no processes and reads no clock.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The first line the probe prints. Anything before it (for example output
/// from a shell start-up file) is ignored.
pub const PROBE_MARKER: &str = "mooring-desktop-probe 1";
/// The last line of a complete probe report.
pub const PROBE_END: &str = "end";
/// Probe output beyond this is never read.
pub const MAX_PROBE_OUTPUT_BYTES: usize = 128 * 1024;
const MAX_NAME_CHARS: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LockState {
    Locked,
    Unlocked,
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DisplayState {
    On,
    Off,
    Unknown,
}

/// What the probe found to read.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    /// A graphical session was found and read.
    Found,
    /// logind lists no graphical session.
    NoSession,
    /// The host has no systemd-logind, so the probe cannot find a session.
    NoLogind,
    /// SSH signed in as a different user from the session's, without root.
    NotReadable,
}

/// The report that decided [`LockState`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LockEvidence {
    HyprlandSessionLock,
    OmarchyLockScreen,
    LogindLockedHint,
    None,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct DesktopStatus {
    pub lock: LockState,
    pub display: DisplayState,
    pub session: SessionState,
    pub evidence: LockEvidence,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_user: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compositor: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lock_screen: Option<String>,
    /// The lock screen is checking a password or fingerprint right now.
    pub authenticating: bool,
    /// Hyprland is set to turn the display on for pointer movement or a key.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_wakes_display: Option<bool>,
    /// A short heading, such as "Locked".
    pub title: String,
    /// One or two sentences for the person, saying what to do.
    pub message: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub notes: Vec<String>,
}

impl DesktopStatus {
    /// Whether reading again could give a different answer.
    pub fn can_change(&self) -> bool {
        matches!(self.session, SessionState::Found | SessionState::NoSession)
    }
}

#[derive(Debug, Deserialize)]
struct HyprMonitor {
    #[serde(rename = "dpmsStatus")]
    dpms_status: Option<bool>,
    #[serde(default)]
    disabled: bool,
    #[serde(rename = "solitaryBlockedBy")]
    solitary_blocked_by: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct OmarchyLock {
    locked: bool,
    #[serde(default)]
    authenticating: bool,
}

#[derive(Debug, Default)]
struct Probe {
    no_logind: bool,
    no_session: bool,
    not_readable: bool,
    user: Option<String>,
    session_type: Option<String>,
    desktop: Option<String>,
    locked_hint: Option<bool>,
    monitors: Option<Vec<HyprMonitor>>,
    hyprland_unreadable: bool,
    wake_options: Vec<bool>,
    omarchy: Option<OmarchyLock>,
    omarchy_unreadable: bool,
}

/// A name from the remote host, reduced to a short printable string.
fn clean_name(value: &str) -> Option<String> {
    let cleaned: String = value
        .chars()
        .filter(|c| c.is_ascii_graphic())
        .take(MAX_NAME_CHARS)
        .collect();
    (!cleaned.is_empty()).then_some(cleaned)
}

fn yes_no(value: &str) -> Option<bool> {
    match value {
        "yes" => Some(true),
        "no" => Some(false),
        _ => None,
    }
}

/// Read a probe report. Fails if the report is missing or incomplete, so a
/// probe cut short is never mistaken for an unlocked desktop.
pub fn parse_probe(output: &[u8]) -> Result<DesktopStatus, String> {
    let output = &output[..output.len().min(MAX_PROBE_OUTPUT_BYTES)];
    let text = String::from_utf8_lossy(output);
    let mut lines = text.lines().map(str::trim_end);
    if !lines.by_ref().any(|line| line == PROBE_MARKER) {
        return Err("The desktop check returned nothing Mooring recognizes.".into());
    }
    let mut probe = Probe::default();
    let mut complete = false;
    for line in lines {
        if line == PROBE_END {
            complete = true;
            break;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key {
            "logind" => probe.no_logind = value == "absent",
            "session" => probe.no_session = value == "none",
            "session.readable" => probe.not_readable = value == "no",
            "session.Name" => probe.user = clean_name(value),
            "session.Type" => probe.session_type = clean_name(value),
            "session.Desktop" => probe.desktop = clean_name(value),
            "session.LockedHint" => probe.locked_hint = yes_no(value),
            "hyprland" => probe.hyprland_unreadable = value == "unreadable",
            "hyprland.monitors" => probe.monitors = serde_json::from_str(value).ok(),
            "hyprland.option" => {
                if let Ok(option) = serde_json::from_str::<Value>(value) {
                    // Hyprland reports booleans as "bool" now and "int" before.
                    let enabled = option
                        .get("bool")
                        .and_then(Value::as_bool)
                        .or_else(|| option.get("int").and_then(Value::as_i64).map(|v| v != 0));
                    if let Some(enabled) = enabled {
                        probe.wake_options.push(enabled);
                    }
                }
            }
            "omarchy.lock" => probe.omarchy = serde_json::from_str(value).ok(),
            "omarchy" => probe.omarchy_unreadable = value == "unreadable",
            _ => {}
        }
    }
    if !complete {
        return Err("The desktop check stopped before it finished.".into());
    }
    Ok(evaluate(probe))
}

/// Hyprland's view of the session lock across monitors, as Omarchy reads it:
/// any `LOCK` reason means locked. Hyprland stops listing reasons at the
/// first one on a monitor with no workspace (`WORKSPACE`), so a monitor like
/// that says nothing either way.
fn hyprland_lock(monitors: &[HyprMonitor]) -> Option<bool> {
    let mut readable = false;
    for monitor in monitors {
        let Some(Value::Array(reasons)) = &monitor.solitary_blocked_by else {
            continue;
        };
        let has = |name: &str| reasons.iter().any(|r| r.as_str() == Some(name));
        if has("LOCK") {
            return Some(true);
        }
        readable |= !has("WORKSPACE");
    }
    readable.then_some(false)
}

fn display_state(monitors: &[HyprMonitor]) -> DisplayState {
    let mut states = monitors
        .iter()
        .filter(|m| !m.disabled)
        .filter_map(|m| m.dpms_status);
    match states.next() {
        None => DisplayState::Unknown,
        Some(first) if first || states.any(|on| on) => DisplayState::On,
        Some(_) => DisplayState::Off,
    }
}

/// Desktops whose lock screens are known to keep logind's LockedHint current.
fn sets_locked_hint(desktop: Option<&str>) -> bool {
    desktop.is_some_and(|d| {
        let d = d.to_ascii_lowercase();
        ["gnome", "ubuntu", "kde", "plasma"]
            .iter()
            .any(|known| d.contains(known))
    })
}

fn evaluate(probe: Probe) -> DesktopStatus {
    let hypr_lock = probe.monitors.as_deref().and_then(hyprland_lock);
    let omarchy_lock = probe.omarchy.as_ref().map(|lock| lock.locked);
    let mut notes = Vec::new();
    let session = if probe.no_logind {
        SessionState::NoLogind
    } else if probe.no_session {
        SessionState::NoSession
    } else if probe.not_readable {
        SessionState::NotReadable
    } else {
        SessionState::Found
    };
    let (lock, evidence) = if hypr_lock == Some(true) {
        if omarchy_lock == Some(false) {
            notes.push("Hyprland holds a session lock that the Omarchy lock screen does not own. If the screen shows a lock-screen error, sign in at the computer.".to_string());
        }
        (LockState::Locked, LockEvidence::HyprlandSessionLock)
    } else if omarchy_lock == Some(true) {
        (LockState::Locked, LockEvidence::OmarchyLockScreen)
    } else if hypr_lock == Some(false) {
        (LockState::Unlocked, LockEvidence::HyprlandSessionLock)
    } else if omarchy_lock == Some(false) {
        (LockState::Unlocked, LockEvidence::OmarchyLockScreen)
    } else if probe.locked_hint == Some(true) {
        (LockState::Locked, LockEvidence::LogindLockedHint)
    } else if probe.locked_hint == Some(false) && sets_locked_hint(probe.desktop.as_deref()) {
        (LockState::Unlocked, LockEvidence::LogindLockedHint)
    } else {
        (LockState::Unknown, LockEvidence::None)
    };
    if lock == LockState::Unlocked
        && evidence != LockEvidence::LogindLockedHint
        && probe.locked_hint == Some(true)
    {
        notes.push("logind still marks the session locked; Mooring goes by the compositor and lock screen.".into());
    }
    if probe.hyprland_unreadable {
        notes.push("Hyprland did not answer Mooring's read-only query.".into());
    }
    if probe.omarchy_unreadable {
        notes.push("The Omarchy lock screen did not answer Mooring's read-only query.".into());
    }
    let display = probe
        .monitors
        .as_deref()
        .map_or(DisplayState::Unknown, display_state);
    let input_wakes_display =
        (!probe.wake_options.is_empty()).then(|| probe.wake_options.iter().any(|enabled| *enabled));
    let authenticating = lock == LockState::Locked
        && probe
            .omarchy
            .as_ref()
            .is_some_and(|lock| lock.authenticating);
    let (title, message) = describe(
        session,
        lock,
        display,
        authenticating,
        input_wakes_display,
        probe.user.as_deref(),
    );
    DesktopStatus {
        lock,
        display,
        session,
        evidence,
        compositor: probe.monitors.as_ref().map(|_| "hyprland".to_string()),
        lock_screen: probe.omarchy.as_ref().map(|_| "omarchy".to_string()),
        session_user: probe.user,
        session_type: probe.session_type,
        authenticating,
        input_wakes_display,
        title,
        message,
        notes,
    }
}

fn describe(
    session: SessionState,
    lock: LockState,
    display: DisplayState,
    authenticating: bool,
    input_wakes_display: Option<bool>,
    user: Option<&str>,
) -> (String, String) {
    const NEVER: &str = "Mooring never types your password.";
    let owner = user.map_or_else(|| "The remote".to_string(), |u| format!("{u}’s"));
    let wake = if input_wakes_display == Some(true) {
        "A key press or pointer movement in the viewer should wake it."
    } else {
        "The viewer may stay dark until the display wakes."
    };
    match (session, lock) {
        (SessionState::NoLogind, _) => (
            "Lock state unknown".into(),
            "This host has no systemd-logind, so Mooring can’t tell whether its screen is locked.".into(),
        ),
        (SessionState::NoSession, _) => (
            "No desktop session".into(),
            "No one is signed in to a graphical desktop there. A VNC server such as wayvnc needs a signed-in desktop session.".into(),
        ),
        (SessionState::NotReadable, _) => (
            "Lock state unknown".into(),
            match user {
                Some(user) => format!("SSH signs in as a different user from {user}, so Mooring can’t read that session. Save the SSH target as {user}@host to see whether it is locked."),
                None => "SSH signs in as a different user from the desktop’s, so Mooring can’t read that session.".into(),
            },
        ),
        (SessionState::Found, LockState::Locked) if authenticating => (
            "Locked: checking sign-in".into(),
            format!("{owner} screen is locked and is checking a sign-in now. {NEVER}"),
        ),
        (SessionState::Found, LockState::Locked) if display == DisplayState::Off => (
            "Locked: display off".into(),
            format!("{owner} screen is locked and its display is off. {wake} Then sign in on the lock screen in the viewer. {NEVER}"),
        ),
        (SessionState::Found, LockState::Locked) => (
            "Locked".into(),
            format!("{owner} screen is locked. Sign in on the lock screen in the viewer. {NEVER}"),
        ),
        (SessionState::Found, LockState::Unlocked) if display == DisplayState::Off => (
            "Unlocked: display off".into(),
            format!("{owner} desktop is unlocked, but its display is off. {wake}"),
        ),
        (SessionState::Found, LockState::Unlocked) => (
            "Unlocked".into(),
            format!("{owner} desktop is unlocked."),
        ),
        (SessionState::Found, LockState::Unknown) => (
            "Lock state unknown".into(),
            format!("Mooring couldn’t tell whether {} screen is locked. Its lock screen doesn’t report to logind, and no Hyprland or Omarchy status was readable.", user.map_or_else(|| "the remote".to_string(), |u| format!("{u}’s"))),
        ),
    }
}

/// How often to read the desktop while a viewer session is open.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct DesktopWatchLimits {
    /// While locked, read often, so the indicator clears soon after sign-in.
    pub locked_interval_ms: u64,
    pub unlocked_interval_ms: u64,
    pub unknown_interval_ms: u64,
    pub failure_interval_ms: u64,
    /// Stop reading after this many failed reads in a row.
    pub max_consecutive_failures: u32,
}

impl Default for DesktopWatchLimits {
    fn default() -> Self {
        Self {
            locked_interval_ms: 10_000,
            unlocked_interval_ms: 30_000,
            unknown_interval_ms: 60_000,
            failure_interval_ms: 30_000,
            max_consecutive_failures: 3,
        }
    }
}

pub const MIN_WATCH_INTERVAL_MS: u64 = 1_000;
pub const MAX_WATCH_INTERVAL_MS: u64 = 60 * 60 * 1000;
pub const MAX_WATCH_FAILURES: u32 = 10;

impl DesktopWatchLimits {
    pub fn validate(&self) -> Result<(), String> {
        let intervals = [
            self.locked_interval_ms,
            self.unlocked_interval_ms,
            self.unknown_interval_ms,
            self.failure_interval_ms,
        ];
        if intervals
            .iter()
            .any(|ms| !(MIN_WATCH_INTERVAL_MS..=MAX_WATCH_INTERVAL_MS).contains(ms))
        {
            return Err("Desktop check intervals must be between 1 second and 1 hour.".into());
        }
        if !(1..=MAX_WATCH_FAILURES).contains(&self.max_consecutive_failures) {
            return Err(format!(
                "Desktop check failures must be between 1 and {MAX_WATCH_FAILURES}."
            ));
        }
        Ok(())
    }
}

/// What to do after a failed read.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WatchFailure {
    /// The first failure in a row: tell the person, then retry later.
    Report,
    /// A repeat failure: retry later without repeating the report.
    Quiet,
    /// The failure budget is spent: stop reading.
    Stop,
}

/// When to read the desktop again, and which results are worth reporting.
/// Only changes are reported, so a steady state prints one line.
#[derive(Clone, Debug)]
pub struct DesktopWatch {
    limits: DesktopWatchLimits,
    next_due_ms: Option<u64>,
    last: Option<(LockState, DisplayState, SessionState, bool)>,
    failures: u32,
}

impl DesktopWatch {
    /// The first read is due at `now_ms`.
    pub fn new(limits: DesktopWatchLimits, now_ms: u64) -> Result<Self, String> {
        limits.validate()?;
        Ok(Self {
            limits,
            next_due_ms: Some(now_ms),
            last: None,
            failures: 0,
        })
    }

    /// When the next read is due, or `None` once watching has stopped.
    pub fn next_due_ms(&self) -> Option<u64> {
        self.next_due_ms
    }

    pub fn stop(&mut self) {
        self.next_due_ms = None;
    }

    /// Record a successful read. Returns true if it should be reported.
    pub fn record_status(&mut self, now_ms: u64, status: &DesktopStatus) -> bool {
        self.failures = 0;
        let interval = match status.lock {
            _ if !status.can_change() => None,
            LockState::Locked => Some(self.limits.locked_interval_ms),
            LockState::Unlocked => Some(self.limits.unlocked_interval_ms),
            LockState::Unknown => Some(self.limits.unknown_interval_ms),
        };
        self.next_due_ms = interval.map(|ms| now_ms.saturating_add(ms));
        let signature = (
            status.lock,
            status.display,
            status.session,
            status.authenticating,
        );
        let changed = self.last != Some(signature);
        self.last = Some(signature);
        changed
    }

    /// Record a failed read.
    pub fn record_failure(&mut self, now_ms: u64) -> WatchFailure {
        self.failures += 1;
        if self.failures >= self.limits.max_consecutive_failures {
            self.next_due_ms = None;
            return WatchFailure::Stop;
        }
        self.next_due_ms = Some(now_ms.saturating_add(self.limits.failure_interval_ms));
        if self.failures == 1 {
            // A later success should be reported even if it matches the last.
            self.last = None;
            WatchFailure::Report
        } else {
            WatchFailure::Quiet
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LOCKED_OMARCHY: &str = r#"Welcome to the host
mooring-desktop-probe 1
ssh.uid=0
session.Id=6
session.User=1001
session.Name=alex
session.Desktop=
session.Type=wayland
session.Active=yes
session.LockedHint=no
hyprland.monitors=[{    "id": 0,    "name": "eDP-1",    "dpmsStatus": false,    "disabled": false,    "solitaryBlockedBy": ["LOCK", "WINDOWED", "CANDIDATE"]}]
hyprland.option={"option": "misc:mouse_move_enables_dpms", "bool": true, "set": true }
hyprland.option={"option": "misc:key_press_enables_dpms", "bool": true, "set": true }
omarchy.lock={"locked":true,"requested":true,"pending":false,"sessionLocked":true,"secure":true,"realScreens":1,"passwordPam":true,"fingerprint":false,"authenticating":false,"lastEvent":"secure=true","lastEventAt":"2026-11-02T06:00:57.507Z"}
end
"#;

    fn probe(lines: &[&str]) -> Vec<u8> {
        let mut text = format!("{PROBE_MARKER}\n");
        for line in lines {
            text.push_str(line);
            text.push('\n');
        }
        text.push_str("end\n");
        text.into_bytes()
    }

    fn monitors(entries: &[(&str, bool, &str)]) -> String {
        let list: Vec<String> = entries
            .iter()
            .map(|(name, dpms, reasons)| {
                format!(r#"{{"name":"{name}","dpmsStatus":{dpms},"disabled":false,"solitaryBlockedBy":{reasons}}}"#)
            })
            .collect();
        format!("hyprland.monitors=[{}]", list.join(","))
    }

    #[test]
    fn reads_a_locked_omarchy_desktop_with_the_display_off() {
        let status = parse_probe(LOCKED_OMARCHY.as_bytes()).unwrap();
        assert_eq!(status.lock, LockState::Locked);
        assert_eq!(status.display, DisplayState::Off);
        assert_eq!(status.session, SessionState::Found);
        assert_eq!(status.evidence, LockEvidence::HyprlandSessionLock);
        assert_eq!(status.session_user.as_deref(), Some("alex"));
        assert_eq!(status.session_type.as_deref(), Some("wayland"));
        assert_eq!(status.compositor.as_deref(), Some("hyprland"));
        assert_eq!(status.lock_screen.as_deref(), Some("omarchy"));
        assert_eq!(status.input_wakes_display, Some(true));
        assert!(!status.authenticating);
        assert_eq!(status.title, "Locked: display off");
        assert!(status.message.contains("alex’s screen is locked"));
        assert!(status.message.contains("should wake it"));
        assert!(status.message.contains("never types your password"));
        // logind's "no" is not trusted over the compositor, and needs no note.
        assert!(status.notes.is_empty(), "{:?}", status.notes);
        let json = serde_json::to_value(&status).unwrap();
        assert_eq!(json["lock"], "locked");
        assert_eq!(json["display"], "off");
        assert_eq!(json["evidence"], "hyprland_session_lock");
    }

    #[test]
    fn hyprland_without_a_lock_reason_is_unlocked() {
        let status = parse_probe(&probe(&[
            "session.Name=alex",
            &monitors(&[("eDP-1", true, r#"["WINDOWED","CANDIDATE"]"#)]),
            r#"omarchy.lock={"locked":false,"authenticating":false}"#,
        ]))
        .unwrap();
        assert_eq!(
            (status.lock, status.display, status.evidence),
            (
                LockState::Unlocked,
                DisplayState::On,
                LockEvidence::HyprlandSessionLock
            )
        );
        assert_eq!(status.title, "Unlocked");
        // A monitor that can go solitary lists no reasons at all.
        let solitary = parse_probe(&probe(&[&monitors(&[("eDP-1", true, "[]")])])).unwrap();
        assert_eq!(solitary.lock, LockState::Unlocked);
    }

    #[test]
    fn a_lock_on_any_monitor_locks_and_any_lit_monitor_is_on() {
        let status = parse_probe(&probe(&[&monitors(&[
            ("DP-1", true, r#"["WINDOWED"]"#),
            ("eDP-1", false, r#"["LOCK"]"#),
        ])]))
        .unwrap();
        assert_eq!(status.lock, LockState::Locked);
        assert_eq!(status.display, DisplayState::On);
        assert_eq!(status.title, "Locked");
        assert!(!status.message.contains("display is off"));
    }

    #[test]
    fn a_monitor_without_a_workspace_says_nothing() {
        // Hyprland stops at WORKSPACE before it reaches LOCK.
        let status =
            parse_probe(&probe(&[&monitors(&[("eDP-1", true, r#"["WORKSPACE"]"#)])])).unwrap();
        assert_eq!(status.lock, LockState::Unknown);
        assert_eq!(status.evidence, LockEvidence::None);
        // Without solitaryBlockedBy (older Hyprland), the lock screen decides.
        let old = parse_probe(&probe(&[
            r#"hyprland.monitors=[{"name":"eDP-1","dpmsStatus":true}]"#,
            r#"omarchy.lock={"locked":true,"authenticating":true}"#,
        ]))
        .unwrap();
        assert_eq!(
            (old.lock, old.evidence, old.authenticating),
            (LockState::Locked, LockEvidence::OmarchyLockScreen, true)
        );
        assert_eq!(old.title, "Locked: checking sign-in");
    }

    #[test]
    fn a_stranded_compositor_lock_is_still_locked() {
        let status = parse_probe(&probe(&[
            &monitors(&[("eDP-1", true, r#"["LOCK"]"#)]),
            r#"omarchy.lock={"locked":false}"#,
        ]))
        .unwrap();
        assert_eq!(status.lock, LockState::Locked);
        assert!(
            status.notes[0].contains("does not own"),
            "{:?}",
            status.notes
        );
    }

    #[test]
    fn logind_is_trusted_only_where_it_is_kept_current() {
        let locked =
            parse_probe(&probe(&["session.LockedHint=yes", "session.Desktop=sway"])).unwrap();
        assert_eq!(
            (locked.lock, locked.evidence),
            (LockState::Locked, LockEvidence::LogindLockedHint)
        );
        assert_eq!(locked.display, DisplayState::Unknown);
        assert!(locked.message.contains("The remote screen is locked"));
        let gnome =
            parse_probe(&probe(&["session.LockedHint=no", "session.Desktop=GNOME"])).unwrap();
        assert_eq!(gnome.lock, LockState::Unlocked);
        let sway = parse_probe(&probe(&["session.LockedHint=no", "session.Desktop=sway"])).unwrap();
        assert_eq!(sway.lock, LockState::Unknown);
        assert!(sway.message.contains("couldn’t tell"));
        // The compositor wins over a stale hint, with a note.
        let stale = parse_probe(&probe(&[
            "session.LockedHint=yes",
            &monitors(&[("eDP-1", true, r#"["WINDOWED"]"#)]),
        ]))
        .unwrap();
        assert_eq!(stale.lock, LockState::Unlocked);
        assert!(stale.notes[0].contains("logind still marks"));
    }

    #[test]
    fn hosts_without_a_readable_session_say_why() {
        let none = parse_probe(&probe(&["session=none"])).unwrap();
        assert_eq!(
            (none.session, none.lock, none.title.as_str()),
            (
                SessionState::NoSession,
                LockState::Unknown,
                "No desktop session"
            )
        );
        assert!(none.can_change());
        let no_logind = parse_probe(&probe(&["logind=absent"])).unwrap();
        assert_eq!(no_logind.session, SessionState::NoLogind);
        assert!(!no_logind.can_change());
        let other_user =
            parse_probe(&probe(&["session.Name=alex", "session.readable=no"])).unwrap();
        assert_eq!(other_user.session, SessionState::NotReadable);
        assert!(other_user.message.contains("alex@host"));
        assert!(!other_user.can_change());
        let silent = parse_probe(&probe(&[
            "session.Name=alex",
            "hyprland=unreadable",
            "omarchy=unreadable",
        ]))
        .unwrap();
        assert_eq!(silent.lock, LockState::Unknown);
        assert_eq!(silent.notes.len(), 2);
    }

    #[test]
    fn incomplete_or_foreign_output_is_an_error_not_unlocked() {
        assert!(parse_probe(b"").is_err());
        assert!(parse_probe(b"sh: 1: /bin/sh: not found\n").is_err());
        let cut = format!("{PROBE_MARKER}\nsession.Name=alex\n");
        assert!(
            parse_probe(cut.as_bytes())
                .unwrap_err()
                .contains("before it finished")
        );
        // The report must start at the marker, not merely contain "end".
        assert!(parse_probe(b"end\n").is_err());
    }

    #[test]
    fn remote_strings_are_bounded_and_printable() {
        let long = format!("session.Name={}\u{1b}[31m", "a".repeat(500));
        let status = parse_probe(&probe(&[&long, "session.Type=way land"])).unwrap();
        let user = status.session_user.unwrap();
        assert_eq!(user.len(), MAX_NAME_CHARS);
        assert!(user.chars().all(|c| c.is_ascii_graphic()));
        assert_eq!(status.session_type.as_deref(), Some("wayland"));
        // Malformed JSON is ignored rather than trusted.
        let garbage =
            parse_probe(&probe(&["hyprland.monitors=[{", "omarchy.lock=locked"])).unwrap();
        assert_eq!(garbage.lock, LockState::Unknown);
        // Output past the cap is never read, so a report there is incomplete.
        let mut huge = format!("{PROBE_MARKER}\n").into_bytes();
        huge.resize(MAX_PROBE_OUTPUT_BYTES + 10, b'x');
        huge.extend_from_slice(b"\nend\n");
        assert!(parse_probe(&huge).is_err());
    }

    #[test]
    fn older_hyprland_reports_wake_options_as_integers() {
        let status = parse_probe(&probe(&[
            &monitors(&[("eDP-1", false, r#"["WINDOWED"]"#)]),
            r#"hyprland.option={"option":"misc:mouse_move_enables_dpms","int":0,"set":false}"#,
            r#"hyprland.option={"option":"misc:key_press_enables_dpms","int":0,"set":false}"#,
        ]))
        .unwrap();
        assert_eq!(status.input_wakes_display, Some(false));
        assert_eq!(status.title, "Unlocked: display off");
        assert!(status.message.contains("may stay dark"));
    }

    fn locked() -> DesktopStatus {
        parse_probe(LOCKED_OMARCHY.as_bytes()).unwrap()
    }

    fn unlocked() -> DesktopStatus {
        parse_probe(&probe(&[&monitors(&[("eDP-1", true, r#"["WINDOWED"]"#)])])).unwrap()
    }

    #[test]
    fn watching_reports_only_changes_and_reads_sooner_while_locked() {
        let limits = DesktopWatchLimits::default();
        let mut watch = DesktopWatch::new(limits, 0).unwrap();
        assert_eq!(watch.next_due_ms(), Some(0));
        assert!(watch.record_status(0, &locked()));
        assert_eq!(watch.next_due_ms(), Some(limits.locked_interval_ms));
        assert!(!watch.record_status(10_000, &locked()));
        assert!(watch.record_status(20_000, &unlocked()));
        assert_eq!(
            watch.next_due_ms(),
            Some(20_000 + limits.unlocked_interval_ms)
        );
        assert!(!watch.record_status(50_000, &unlocked()));
    }

    #[test]
    fn failures_are_reported_once_and_bounded() {
        let mut watch = DesktopWatch::new(DesktopWatchLimits::default(), 0).unwrap();
        assert!(watch.record_status(0, &locked()));
        assert_eq!(watch.record_failure(10_000), WatchFailure::Report);
        assert_eq!(watch.next_due_ms(), Some(40_000));
        // After a failure, the same state is reported again.
        assert!(watch.record_status(40_000, &locked()));
        assert_eq!(watch.record_failure(50_000), WatchFailure::Report);
        assert_eq!(watch.record_failure(80_000), WatchFailure::Quiet);
        assert_eq!(watch.record_failure(110_000), WatchFailure::Stop);
        assert_eq!(watch.next_due_ms(), None);
    }

    #[test]
    fn states_that_cannot_change_stop_the_watch() {
        let mut watch = DesktopWatch::new(DesktopWatchLimits::default(), 0).unwrap();
        let other_user = parse_probe(&probe(&["session.readable=no"])).unwrap();
        assert!(watch.record_status(0, &other_user));
        assert_eq!(watch.next_due_ms(), None);
        let mut waiting = DesktopWatch::new(DesktopWatchLimits::default(), 0).unwrap();
        waiting.record_status(0, &parse_probe(&probe(&["session=none"])).unwrap());
        assert_eq!(waiting.next_due_ms(), Some(60_000));
        waiting.stop();
        assert_eq!(waiting.next_due_ms(), None);
    }

    #[test]
    fn watch_limits_are_bounded() {
        assert!(DesktopWatchLimits::default().validate().is_ok());
        for limits in [
            DesktopWatchLimits {
                locked_interval_ms: 999,
                ..Default::default()
            },
            DesktopWatchLimits {
                unknown_interval_ms: MAX_WATCH_INTERVAL_MS + 1,
                ..Default::default()
            },
            DesktopWatchLimits {
                max_consecutive_failures: 0,
                ..Default::default()
            },
            DesktopWatchLimits {
                max_consecutive_failures: MAX_WATCH_FAILURES + 1,
                ..Default::default()
            },
        ] {
            assert!(limits.validate().is_err(), "{limits:?}");
            assert!(DesktopWatch::new(limits, 0).is_err());
        }
    }
}
