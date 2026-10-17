//! Linux virtual keyboard and wheel; Hyprland positions the pointer in layout coordinates.
use super::{Monitor, command};
use mooring_session::ffi::*;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::time::Instant;

// Apple virtual key positions -> Linux evdev codes. Layout interpretation stays on Linux.
fn key(code: u16) -> Option<u16> {
    const KEYS: [u16; 128] = [
        30, 31, 32, 33, 35, 34, 44, 45, 46, 47, 86, 48, 16, 17, 18, 19, 21, 20, 2, 3, 4, 5, 7, 6,
        13, 10, 8, 12, 9, 11, 27, 24, 22, 26, 23, 25, 28, 38, 36, 40, 37, 39, 43, 51, 53, 49, 50,
        52, 15, 57, 41, 14, 0, 1, 126, 125, 42, 58, 56, 29, 54, 100, 97, 0, 0, 83, 0, 55, 0, 78, 0,
        69, 0, 0, 0, 98, 96, 0, 74, 0, 0, 117, 82, 79, 80, 81, 75, 76, 77, 71, 0, 72, 73, 0, 0, 0,
        63, 64, 65, 61, 66, 67, 0, 87, 0, 99, 0, 70, 0, 68, 0, 88, 0, 119, 110, 102, 104, 111, 62,
        107, 60, 109, 59, 105, 106, 108, 103, 0,
    ];
    KEYS.get(code as usize).copied().filter(|v| *v != 0)
}
#[repr(C)]
struct Setup {
    id: [u16; 4],
    name: [u8; 80],
    effects: u32,
}
#[repr(C)]
struct Event {
    time: libc::timeval,
    kind: u16,
    code: u16,
    value: i32,
}
pub struct Input {
    device: File,
    state: *mut MLInputState,
    start: Instant,
    wheel: [f64; 2],
}
impl Input {
    pub fn open() -> Result<Self, String> {
        let device = OpenOptions::new()
            .write(true)
            .open("/dev/uinput")
            .map_err(|e| format!("/dev/uinput: {e}; grant this user access (see docs/LINUX.md)"))?;
        let fd = device.as_raw_fd();
        // Linux UAPI: UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT, UI_DEV_SETUP.
        for event in [1, 2] {
            ioctl(fd, 0x40045564, event)?;
        }
        for code in 1..=127 {
            if let Some(code) = key(code) {
                ioctl(fd, 0x40045565, code as i32)?;
            }
        }
        // Include A (Apple keycode zero) and mouse buttons.
        for code in [30, 272, 273, 274] {
            ioctl(fd, 0x40045565, code)?;
        }
        for code in [0, 1, 6, 8] {
            ioctl(fd, 0x40045566, code)?;
        } // REL_HWHEEL, REL_WHEEL
        let mut setup = Setup {
            id: [3, 0x1209, 0x4d4f, 1],
            name: [0; 80],
            effects: 0,
        };
        setup.name[..13].copy_from_slice(b"Mooring input");
        // SAFETY: fd is a live uinput descriptor, and setup has Linux UAPI layout.
        if unsafe { libc::ioctl(fd, 0x405c5503, &setup) } < 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        ioctl(fd, 0x5501, 0)?;
        let state = ml_input_state_new();
        if state.is_null() {
            return Err("input reducer allocation failed".into());
        }
        Ok(Self {
            device,
            state,
            start: Instant::now(),
            wheel: [0.0; 2],
        })
    }
    fn event(&mut self, kind: u16, code: u16, value: i32) -> Result<(), String> {
        let event = Event {
            time: libc::timeval {
                tv_sec: 0,
                tv_usec: 0,
            },
            kind,
            code,
            value,
        };
        // SAFETY: all fields (including timeval) are initialized; Linux input_event layout.
        let bytes = unsafe {
            std::slice::from_raw_parts(
                (&event as *const Event).cast::<u8>(),
                std::mem::size_of::<Event>(),
            )
        };
        self.device.write_all(bytes).map_err(|e| e.to_string())
    }
    fn post(&mut self, e: MLInputEvent, monitor: &Monitor) -> Result<(), String> {
        match e.kind {
            1 | 2 => {
                if let Some(code) = key(e.key_code) {
                    self.event(
                        1,
                        code,
                        if e.kind == 2 {
                            0
                        } else if e.is_repeat != 0 {
                            2
                        } else {
                            1
                        },
                    )?;
                }
            }
            3..=5 => {
                let x = monitor.x + (e.x * (monitor.width - 1.0)).round();
                let y = monitor.y + (e.y * (monitor.height - 1.0)).round();
                command(
                    "hyprctl",
                    &["dispatch", "movecursor", &format!("{x:.0} {y:.0}")],
                )?;
                if e.kind != 3 {
                    self.event(
                        1,
                        [272, 273, 274][e.button as usize],
                        i32::from(e.kind == 4),
                    )?;
                }
            }
            6 => {
                // Preserve sub-detent trackpad deltas across events.
                for (axis, code, delta) in [(0, 6, e.delta_x), (1, 8, e.delta_y)] {
                    let steps = wheel_steps(&mut self.wheel[axis], delta);
                    if steps != 0 {
                        self.event(2, code, steps)?;
                    }
                }
            }
            _ => {}
        }
        self.event(0, 0, 0)
    }
    pub fn accept(&mut self, e: &MLInputEvent, monitor: &Monitor) -> Result<(), String> {
        let mut out = [MLInputEvent::default(); 132];
        let mut count = 0;
        let mut buttons = 0;
        // SAFETY: live reducer and fully sized output array.
        super::check(unsafe {
            ml_input_state_accept(
                self.state,
                e,
                self.start.elapsed().as_secs_f64(),
                out.as_mut_ptr(),
                out.len(),
                &mut count,
                &mut buttons,
            )
        })?;
        for e in &out[..count] {
            self.post(*e, monitor)?;
        }
        // SAFETY: reducer owned by this thread.
        super::check(unsafe { ml_input_state_commit(self.state) })
    }
}
fn wheel_steps(pending: &mut f64, delta: f64) -> i32 {
    *pending += delta / 15.0;
    let steps = pending.trunc().clamp(-80.0, 80.0) as i32;
    *pending -= f64::from(steps);
    steps
}
fn ioctl(fd: i32, request: u64, value: i32) -> Result<(), String> {
    // SAFETY: requests here take an integer or no argument, on a live uinput fd.
    if unsafe { libc::ioctl(fd, request as _, value) } < 0 {
        Err(std::io::Error::last_os_error().to_string())
    } else {
        Ok(())
    }
}
impl Drop for Input {
    fn drop(&mut self) {
        // Destroying the virtual device releases every held key/button even after a failed injection.
        let _ = ioctl(self.device.as_raw_fd(), 0x5502, 0);
        // SAFETY: owned reducer, freed exactly once.
        unsafe { ml_input_state_free(self.state) };
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn key_positions_and_modifiers() {
        assert_eq!(key(0), Some(30));
        assert_eq!(key(36), Some(28));
        assert_eq!(key(55), Some(125));
        assert_eq!(key(56), Some(42));
        assert_eq!(key(59), Some(29));
        assert_eq!(key(123), Some(105));
        assert_eq!(key(128), None);
    }
    #[test]
    fn smooth_scroll_accumulates_and_reverses() {
        let mut pending = 0.0;
        assert_eq!(wheel_steps(&mut pending, 5.0), 0);
        assert_eq!(wheel_steps(&mut pending, 5.0), 0);
        assert_eq!(wheel_steps(&mut pending, 5.0), 1);
        assert_eq!(wheel_steps(&mut pending, -15.0), -1);
    }
    #[test]
    fn uapi_layout() {
        assert_eq!(std::mem::size_of::<Setup>(), 92);
        assert_eq!(std::mem::size_of::<Event>(), 24);
    }
}
