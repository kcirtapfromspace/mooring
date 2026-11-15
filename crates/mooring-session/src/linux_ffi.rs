//! Fixed-layout adapter for the pure Linux application lifecycle.
use mooring_core::linux_session::{Event, LinuxSession};

#[derive(Default)]
#[repr(C)]
pub struct MLLinuxFlow {
    pub generation: u64,
    pub phase: u32,
    pub port: u16,
    pub reserved: u16,
}

/// # Safety
/// `state` must point to a live, exclusively borrowed MLLinuxFlow.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ml_linux_flow_step(
    state: *mut MLLinuxFlow,
    generation: u64,
    event: u32,
    port: u16,
) -> i32 {
    let Some(raw) = (unsafe { state.as_mut() }) else {
        return -1;
    };
    let Some(mut flow) = LinuxSession::restore(raw.generation, raw.phase, raw.port) else {
        return -1;
    };
    let event = match event {
        1 => Event::TunnelReady(port),
        2 => Event::DesktopReadyOrTimedOut,
        3 => Event::ViewerStarted,
        4 => Event::RetryRequested,
        5 => Event::Close,
        6 => Event::ViewerEnded,
        _ => return -1,
    };
    let action = flow.apply(generation, event) as i32;
    raw.phase = flow.phase() as u32;
    raw.port = flow.port();
    action
}
