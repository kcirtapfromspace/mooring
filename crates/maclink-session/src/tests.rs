//! Loopback transport and C ABI tests. The accepting side is always the host;
//! the connecting side is the viewer.

use crate::Error;
use crate::ffi::*;
use crate::policy::{CLIPBOARD, CONTROL, INPUT, TELEMETRY, VIDEO};
use crate::transport::{
    HANDSHAKE_PAYLOAD, MAX_CONTROL, MAX_INPUT, MAX_RECORD, MAX_VIDEO, PROLOGUE, builder, deadline,
    read_record, session, write_exact, write_record,
};
use crate::video::tests::{IDR, P_SLICE, PPS, SPS};
use std::ffi::{CString, c_char};
use std::net::{Shutdown, TcpStream};
use std::sync::atomic::Ordering;
use std::sync::mpsc;
use std::time::{Duration, Instant};

struct Owned(u64);
impl Drop for Owned {
    fn drop(&mut self) {
        let _ = ml_session_close(self.0);
    }
}
fn identity() -> ([u8; 32], [u8; 32], [u8; 32]) {
    let (mut private, mut public, mut psk) = ([0; 32], [0; 32], [0; 32]);
    assert_eq!(
        unsafe {
            ml_session_generate_identity(
                private.as_mut_ptr(),
                public.as_mut_ptr(),
                psk.as_mut_ptr(),
            )
        },
        0
    );
    (private, public, psk)
}
fn bind(private: &[u8; 32], psk: &[u8; 32]) -> Owned {
    let mut id = 0;
    assert_eq!(
        unsafe {
            ml_session_listen(
                c"127.0.0.1".as_ptr(),
                0,
                private.as_ptr(),
                psk.as_ptr(),
                &mut id,
            )
        },
        0
    );
    assert_ne!(ml_session_listener_port(id), 0);
    Owned(id)
}
fn connect(port: u16, public: &[u8; 32], psk: &[u8; 32], timeout: u32, out: &mut u64) -> i32 {
    unsafe {
        ml_session_connect(
            c"127.0.0.1".as_ptr(),
            port,
            public.as_ptr(),
            psk.as_ptr(),
            timeout,
            out,
        )
    }
}
/// Returns (viewer, host) on protocol 4: the framing tests below inject raw
/// records whose counters start at zero, which a protocol 5 Hello would take.
fn pair() -> (Owned, Owned) {
    pair_version(4)
}
fn pair_version(offer: u32) -> (Owned, Owned) {
    crate::transport::TEST_OFFER.with(|value| value.set(offer));
    let (private, public, psk) = identity();
    let listener = bind(&private, &psk);
    let id = listener.0;
    let accept = std::thread::spawn(move || {
        let mut host = 0;
        assert_eq!(unsafe { ml_session_accept(id, 5000, &mut host) }, 0);
        Owned(host)
    });
    let mut viewer = 0;
    assert_eq!(
        connect(
            ml_session_listener_port(id),
            &public,
            &psk,
            5000,
            &mut viewer
        ),
        0
    );
    (Owned(viewer), accept.join().unwrap())
}
fn status(result: crate::Result<()>) -> i32 {
    match result {
        Ok(()) => 0,
        Err(error) => error as i32,
    }
}
fn send(id: u64, kind: u8, value: &[u8]) -> i32 {
    status(
        session(id)
            .and_then(|value_session| value_session.send_bytes(kind, value, deadline(5000)?)),
    )
}
/// Untyped receive. Returns the buffer the message used, or both on failure.
fn receive(id: u64, capacity: usize, timeout: u32) -> (i32, u8, usize, Vec<u8>) {
    let (mut video, mut small) = (vec![0; capacity], vec![0; capacity.min(MAX_CONTROL)]);
    let mut needed = 0;
    let result = session(id).and_then(|value| {
        value.receive_bytes(&mut video, &mut small, deadline(timeout)?, &mut needed)
    });
    match result {
        Ok((kind, size)) => (
            0,
            kind,
            size,
            if kind == VIDEO || kind == CLIPBOARD {
                video
            } else {
                small
            },
        ),
        Err(error) => (error as i32, 0, needed, [video, small].concat()),
    }
}
fn plain(kind: u8, total: u32, sequence: u64, offset: u32, payload: &[u8]) -> Vec<u8> {
    let mut data = vec![1, kind, 0, 0];
    data.extend_from_slice(&sequence.to_be_bytes());
    data.extend_from_slice(&total.to_be_bytes());
    data.extend_from_slice(&offset.to_be_bytes());
    data.extend_from_slice(payload);
    data
}
fn encrypted(id: u64, nonce: u64, payload: &[u8]) -> Vec<u8> {
    let sender = session(id).unwrap();
    let mut cipher = vec![0; MAX_RECORD];
    let count = sender
        .crypto
        .write_message(nonce + 1, payload, &mut cipher)
        .unwrap();
    cipher.truncate(count);
    cipher
}
fn inject(id: u64, cipher: &[u8]) {
    write_record(
        &session(id).unwrap().socket,
        cipher,
        deadline(5000).unwrap(),
    )
    .unwrap();
}
fn is_closed(id: u64) -> bool {
    session(id)
        .map(|value| value.closed.load(Ordering::Acquire))
        .unwrap_or(true)
}

fn geometry(kind: u8) -> MLControlMessage {
    MLControlMessage {
        geometry: MLDisplayGeometry {
            x: 0.0,
            y: 0.0,
            width: 1920.0,
            height: 1080.0,
            pixel_width: 1920,
            pixel_height: 1080,
        },
        kind,
        input_enabled: 1,
        ..Default::default()
    }
}
fn control(kind: u8, ping_id: u64) -> MLControlMessage {
    MLControlMessage {
        kind,
        ping_id,
        ..Default::default()
    }
}
fn frame(avcc: &[u8], keyframe: bool, sequence: u64) -> MLVideoFrame {
    MLVideoFrame {
        header: MLVideoHeader {
            sequence,
            timestamp_us: 99,
            width: 1920,
            height: 1080,
            keyframe: keyframe.into(),
            codec: 0,
            reserved: [0; 6],
        },
        sps: SPS.as_ptr(),
        sps_length: SPS.len(),
        pps: PPS.as_ptr(),
        pps_length: PPS.len(),
        avcc: avcc.as_ptr(),
        avcc_length: avcc.len(),
        vps: std::ptr::null(),
        vps_length: 0,
    }
}
fn key_event(kind: u8, code: u16) -> MLInputEvent {
    MLInputEvent {
        kind,
        key_code: code,
        ..Default::default()
    }
}
fn send_control(id: u64, message: &MLControlMessage) -> i32 {
    unsafe { ml_session_send_control(id, message, 1000) }
}
fn send_input(id: u64, event: &MLInputEvent) -> i32 {
    unsafe { ml_session_send_input(id, event, 1000) }
}
fn send_video(id: u64, value: &MLVideoFrame) -> i32 {
    unsafe { ml_session_send_video(id, value, 1000) }
}
fn typed(id: u64, buffer: &mut [u8], timeout: u32) -> (i32, MLSessionMessage) {
    let mut message = MLSessionMessage::default();
    let status =
        unsafe { ml_session_receive(id, buffer.as_mut_ptr(), buffer.len(), &mut message, timeout) };
    (status, message)
}

#[test]
fn generated_identity_has_independent_random_pairing_secrets() {
    let (private, public, psk) = identity();
    let (private2, public2, psk2) = identity();
    assert!(private != [0; 32] && public != [0; 32] && psk != [0; 32]);
    assert!(private != private2 && public != public2 && psk != psk2 && private != psk);
}

#[test]
fn authenticated_duplex_chunks_video_without_blocking_return_input() {
    let (viewer, host) = pair();
    let host_id = host.0;
    let video = vec![0xAB; MAX_VIDEO];
    let writer = std::thread::spawn(move || send(host_id, VIDEO, &video));
    let (finished, received) = mpsc::sync_channel(1);
    let reader = std::thread::spawn(move || {
        let result = receive(host_id, MAX_INPUT, 3000);
        finished
            .send((result.0, result.1, result.3[..result.2].to_vec()))
            .unwrap();
    });
    assert_eq!(send(viewer.0, INPUT, b"keyboard-input"), 0);
    // Return input arrives before the viewer drains the large video stream.
    assert_eq!(
        received.recv_timeout(Duration::from_secs(2)).unwrap(),
        (0, INPUT, b"keyboard-input".to_vec())
    );
    let result = receive(viewer.0, MAX_VIDEO, 5000);
    assert_eq!((result.0, result.1, result.2), (0, VIDEO, MAX_VIDEO));
    assert!(result.3.iter().all(|byte| *byte == 0xAB));
    assert_eq!(writer.join().unwrap(), 0);
    reader.join().unwrap();
    assert_eq!(send(viewer.0, CONTROL, b"configuration"), 0);
    let result = receive(host.0, MAX_CONTROL, 1000);
    assert_eq!((result.0, result.1, result.2), (0, CONTROL, 13));
}

#[test]
fn wrong_psk_and_wrong_pinned_identity_never_publish_session_handles() {
    for wrong_identity in [false, true] {
        let (private, mut public, mut psk) = identity();
        let listener = bind(&private, &psk);
        let id = listener.0;
        let accepting = std::thread::spawn(move || {
            let mut handle = 99;
            let status = unsafe { ml_session_accept(id, 1500, &mut handle) };
            (status, handle)
        });
        if wrong_identity {
            public = identity().1;
        } else {
            psk = identity().2;
        }
        let mut handle = 99;
        assert_ne!(
            connect(
                ml_session_listener_port(id),
                &public,
                &psk,
                1500,
                &mut handle
            ),
            0
        );
        assert_eq!(handle, 0);
        let (status, handle) = accepting.join().unwrap();
        assert_ne!(status, 0);
        assert_eq!(handle, 0);
    }
}

#[test]
fn authentication_tamper_closes_without_returning_plaintext() {
    let (viewer, host) = pair();
    let mut cipher = encrypted(viewer.0, 0, &plain(INPUT, 6, 0, 0, b"secret"));
    cipher[3] ^= 0x40;
    inject(viewer.0, &cipher);
    let result = receive(host.0, MAX_INPUT, 1000);
    assert_eq!((result.0, result.1, result.2), (Error::Auth as i32, 0, 0));
    assert!(result.3.iter().all(|byte| *byte == 0));
    assert_eq!(send(host.0, CONTROL, b"retry"), Error::Closed as i32);
}

#[test]
fn authenticated_header_bounds_types_offsets_sequences_and_direction_are_enforced() {
    let cases = [
        plain(VIDEO, (MAX_VIDEO + 1) as u32, 0, 0, b"x"),
        plain(INPUT, (MAX_INPUT + 1) as u32, 0, 0, b"x"),
        plain(CONTROL, (MAX_CONTROL + 1) as u32, 0, 0, b"x"),
        plain(VIDEO, 1, 0, 0, b"x"), // a host never receives video
        plain(6, 1, 0, 0, b"x"),
        plain(INPUT, 1, 1, 0, b"x"),
        plain(INPUT, 1, 0, 1, b"x"),
        plain(INPUT, 1, 0, 0, b"xx"),
        plain(INPUT, 1, 0, 0, b""),
        vec![0; 3],
    ];
    for invalid in cases {
        let (viewer, host) = pair();
        inject(viewer.0, &encrypted(viewer.0, 0, &invalid));
        let result = receive(host.0, MAX_INPUT, 1000);
        assert_eq!(
            (result.0, result.1, result.2),
            (Error::Protocol as i32, 0, 0)
        );
        assert!(is_closed(host.0));
    }
}

#[test]
fn record_replay_cannot_reuse_a_directional_nonce() {
    let (viewer, host) = pair();
    let cipher = encrypted(viewer.0, 0, &plain(INPUT, 1, 0, 0, b"x"));
    inject(viewer.0, &cipher);
    assert_eq!(receive(host.0, MAX_INPUT, 1000).0, 0);
    inject(viewer.0, &cipher);
    assert_eq!(receive(host.0, MAX_INPUT, 1000).0, Error::Auth as i32);
}

fn set_grace(id: u64, grace: Duration) {
    session(id).unwrap().receive.lock().unwrap().grace = grace;
}

#[test]
fn idle_receive_timeout_is_retryable_but_a_stalled_partial_message_closes() {
    let (viewer, host) = pair();
    set_grace(host.0, Duration::from_millis(60));
    assert_eq!(receive(host.0, MAX_INPUT, 30).0, Error::Timeout as i32);
    assert_eq!(send(viewer.0, INPUT, b"after-timeout"), 0);
    assert_eq!(receive(host.0, MAX_INPUT, 1000).0, 0);
    write_exact(
        &session(viewer.0).unwrap().socket,
        &[0],
        deadline(1000).unwrap(),
    )
    .unwrap();
    let started = Instant::now();
    assert_eq!(receive(host.0, MAX_INPUT, 30).0, Error::Stalled as i32);
    assert!(
        started.elapsed() >= Duration::from_millis(55),
        "the grace outlasts the receive deadline"
    );
    assert_eq!(receive(host.0, MAX_INPUT, 30).0, Error::Closed as i32);
}

#[test]
fn a_message_started_near_the_receive_deadline_may_finish_after_it() {
    // Before this grace, a message whose first record arrived just before the
    // caller's deadline failed as a protocol error and ended the session.
    let (viewer, host) = pair();
    let id = viewer.0;
    let writer = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(120));
        inject(id, &encrypted(id, 0, &plain(INPUT, 2, 0, 0, b"x")));
        std::thread::sleep(Duration::from_millis(200));
        inject(id, &encrypted(id, 1, &plain(INPUT, 2, 0, 1, b"y")));
    });
    let result = receive(host.0, MAX_INPUT, 200);
    writer.join().unwrap();
    assert_eq!((result.0, result.1, result.2), (0, INPUT, 2));
    assert_eq!(&result.3[..2], b"xy");
    assert!(!is_closed(host.0));
}

#[test]
fn truncated_record_and_too_small_caller_buffer_close_session() {
    let (viewer, host) = pair();
    let socket = &session(viewer.0).unwrap().socket;
    write_exact(socket, &[0, 40, 1, 2, 3], deadline(1000).unwrap()).unwrap();
    socket.shutdown(Shutdown::Write).unwrap();
    let result = receive(host.0, MAX_INPUT, 1000);
    assert_ne!(result.0, 0);
    assert_eq!(result.2, 0);
    assert!(is_closed(host.0));

    let (viewer, host) = pair();
    assert_eq!(send(viewer.0, INPUT, b"12345"), 0);
    let result = receive(host.0, 3, 1000);
    assert_eq!((result.0, result.1, result.2), (Error::Buffer as i32, 0, 5));
    assert_eq!(receive(host.0, MAX_INPUT, 30).0, Error::Closed as i32);
}

#[test]
fn cancel_accept_and_pending_handshake_have_bounded_latency() {
    for during_handshake in [false, true] {
        let (private, _, psk) = identity();
        let listener = bind(&private, &psk);
        let id = listener.0;
        let raw = during_handshake
            .then(|| TcpStream::connect(("127.0.0.1", ml_session_listener_port(id))).unwrap());
        let accepting = std::thread::spawn(move || {
            let mut handle = 99;
            let status = unsafe { ml_session_accept(id, 5000, &mut handle) };
            (status, handle)
        });
        std::thread::sleep(Duration::from_millis(30));
        let start = Instant::now();
        assert_eq!(ml_session_close(id), 0);
        let result = accepting.join().unwrap();
        assert_ne!(result.0, 0);
        assert_eq!(result.1, 0);
        assert!(start.elapsed() < Duration::from_secs(1));
        drop(raw);
    }
}

#[test]
fn cancel_receive_preserves_arc_lifetime_and_stale_handles_never_reopen() {
    let (_viewer, host) = pair();
    let id = host.0;
    let receiver = std::thread::spawn(move || receive(id, MAX_INPUT, 5000));
    std::thread::sleep(Duration::from_millis(30));
    let start = Instant::now();
    assert_eq!(ml_session_close(id), 0);
    assert_ne!(receiver.join().unwrap().0, 0);
    assert!(start.elapsed() < Duration::from_secs(1));
    assert_eq!(send(id, CONTROL, b"late"), Error::Closed as i32);
    assert_eq!(ml_session_close(id), Error::Closed as i32);
}

#[test]
fn listener_handshake_and_accept_timeouts_remain_usable() {
    let (private, public, psk) = identity();
    let listener = bind(&private, &psk);
    let id = listener.0;
    let mut output = 99;
    assert_eq!(
        unsafe { ml_session_accept(id, 30, &mut output) },
        Error::Timeout as i32
    );
    assert_eq!(output, 0);
    let raw = TcpStream::connect(("127.0.0.1", ml_session_listener_port(id))).unwrap();
    assert_eq!(
        unsafe { ml_session_accept(id, 30, &mut output) },
        Error::Timeout as i32
    );
    drop(raw);
    let accepting = std::thread::spawn(move || {
        let mut value = 0;
        assert_eq!(unsafe { ml_session_accept(id, 3000, &mut value) }, 0);
        Owned(value)
    });
    let mut viewer = 0;
    assert_eq!(
        connect(
            ml_session_listener_port(id),
            &public,
            &psk,
            3000,
            &mut viewer
        ),
        0
    );
    drop(Owned(viewer));
    drop(accepting.join().unwrap());
}

#[test]
fn validation_rejects_bad_arguments_without_closing_the_session() {
    let (viewer, host) = pair();
    assert_eq!(send(viewer.0, 6, b"x"), Error::Invalid as i32);
    assert_eq!(
        send(viewer.0, INPUT, &vec![0; MAX_INPUT + 1]),
        Error::Invalid as i32
    );
    let event = key_event(1, 0);
    assert_eq!(
        unsafe { ml_session_send_input(viewer.0, std::ptr::null(), 1000) },
        Error::Invalid as i32
    );
    assert_eq!(
        unsafe { ml_session_send_input(viewer.0, &event, 0) },
        Error::Invalid as i32
    );
    assert_eq!(
        unsafe { ml_session_send_input(viewer.0, &event, 30001) },
        Error::Invalid as i32
    );
    let mut message = MLSessionMessage::default();
    assert_eq!(
        unsafe { ml_session_receive(host.0, std::ptr::null_mut(), 5, &mut message, 1000) },
        Error::Invalid as i32
    );
    assert_eq!(
        unsafe { ml_session_receive(host.0, std::ptr::null_mut(), 0, std::ptr::null_mut(), 1000) },
        Error::Invalid as i32
    );
    let mut null_frame = frame(IDR, true, 1);
    null_frame.avcc = std::ptr::null();
    assert_eq!(send_video(host.0, &null_frame), Error::Invalid as i32);
    assert_eq!(send_input(viewer.0, &event), 0, "the session stays open");
    let bad = CString::new("http://user:secret@host/").unwrap();
    let (_, public, psk) = identity();
    let mut handle = 99;
    let status = unsafe {
        ml_session_connect(
            bad.as_ptr(),
            45900,
            public.as_ptr(),
            psk.as_ptr(),
            1000,
            &mut handle,
        )
    };
    assert_eq!((status, handle), (Error::Invalid as i32, 0));
}

#[test]
fn concurrent_reader_rejected_without_affecting_other_direction() {
    let (viewer, host) = pair();
    let value = session(host.0).unwrap();
    let _reader = value.receive.lock().unwrap();
    assert_eq!(receive(host.0, MAX_INPUT, 50).0, Error::Busy as i32);
    assert_eq!(send(host.0, CONTROL, b"duplex"), 0);
    assert_eq!(receive(viewer.0, MAX_INPUT, 1000).0, 0);
}

#[test]
fn matching_first_handshake_without_fresh_key_confirmation_never_publishes_session() {
    let (private, public, psk) = identity();
    let listener = bind(&private, &psk);
    let id = listener.0;
    let accepting = std::thread::spawn(move || {
        let mut value = 99;
        let status = unsafe { ml_session_accept(id, 1000, &mut value) };
        (status, value)
    });
    let mut noise = builder()
        .unwrap()
        .remote_public_key(&public)
        .unwrap()
        .psk(0, &psk)
        .unwrap()
        .prologue(PROLOGUE)
        .unwrap()
        .build_initiator()
        .unwrap();
    let raw = TcpStream::connect(("127.0.0.1", ml_session_listener_port(id))).unwrap();
    let mut record = [0; 1024];
    let count = noise.write_message(HANDSHAKE_PAYLOAD, &mut record).unwrap();
    write_record(&raw, &record[..count], deadline(1000).unwrap()).unwrap();
    assert!(read_record(&raw, &mut record, deadline(1000).unwrap(), &mut 0).is_ok());
    // A copied first handshake has no fresh transport keys and cannot finish.
    drop(raw);
    let result = accepting.join().unwrap();
    assert_ne!(result.0, 0);
    assert_eq!(result.1, 0);
}

#[test]
fn authenticated_chunk_metadata_cannot_change_mid_message() {
    let (viewer, host) = pair();
    inject(
        viewer.0,
        &encrypted(viewer.0, 0, &plain(INPUT, 2, 0, 0, b"x")),
    );
    inject(
        viewer.0,
        &encrypted(viewer.0, 1, &plain(CONTROL, 2, 0, 1, b"y")),
    );
    let result = receive(host.0, MAX_INPUT, 1000);
    assert_eq!(
        (result.0, result.1, result.2),
        (Error::Protocol as i32, 0, 0)
    );
    assert!(result.3.iter().all(|byte| *byte == 0));
}

#[test]
fn send_deadline_and_cancellation_close_blocked_video_writer() {
    let (_viewer, host) = pair();
    let payload = vec![1; MAX_VIDEO];
    let result = session(host.0)
        .unwrap()
        .send_bytes(VIDEO, &payload, deadline(30).unwrap());
    assert_eq!(result, Err(Error::Timeout));
    assert_eq!(
        send(host.0, CONTROL, b"cannot-retry-partial-write"),
        Error::Closed as i32
    );

    let (_viewer, host) = pair();
    let id = host.0;
    let writer = std::thread::spawn(move || send(id, VIDEO, &payload));
    std::thread::sleep(Duration::from_millis(30));
    let start = Instant::now();
    assert_eq!(ml_session_close(id), 0);
    assert_ne!(writer.join().unwrap(), 0);
    assert!(start.elapsed() < Duration::from_secs(1));
}

#[test]
fn typed_messages_round_trip_through_the_c_abi() {
    let (viewer, host) = pair();
    let mut buffer = vec![0; MAX_VIDEO];
    assert_eq!(send_control(host.0, &geometry(1)), 0);
    assert_eq!(send_video(host.0, &frame(IDR, true, 1)), 0);
    assert_eq!(send_video(host.0, &frame(P_SLICE, false, 2)), 0);
    assert_eq!(send_control(host.0, &control(4, u64::MAX)), 0);
    let (status, message) = typed(viewer.0, &mut buffer, 1000);
    assert_eq!(
        (
            status,
            message.kind,
            message.control.kind,
            message.control.input_enabled
        ),
        (0, CONTROL, 1, 1)
    );
    assert_eq!(
        (
            message.control.geometry.pixel_width,
            message.control.geometry.height
        ),
        (1920, 1080.0)
    );
    for (avcc, keyframe, sequence) in [(IDR, 1, 1), (P_SLICE, 0, 2)] {
        let (status, message) = typed(viewer.0, &mut buffer, 1000);
        assert_eq!((status, message.kind), (0, VIDEO));
        let packet = message.video;
        assert_eq!(
            (
                packet.header.keyframe,
                packet.header.sequence,
                packet.header.timestamp_us
            ),
            (keyframe, sequence, 99)
        );
        assert_eq!(
            &buffer[packet.sps_offset..packet.sps_offset + packet.sps_length],
            SPS
        );
        assert_eq!(
            &buffer[packet.pps_offset..packet.pps_offset + packet.pps_length],
            PPS
        );
        assert_eq!(
            &buffer[packet.avcc_offset..packet.avcc_offset + packet.avcc_length],
            avcc
        );
    }
    let (status, message) = typed(viewer.0, &mut buffer, 1000);
    assert_eq!(
        (
            status,
            message.kind,
            message.control.kind,
            message.control.ping_id
        ),
        (0, CONTROL, 4, u64::MAX)
    );

    let scroll = MLInputEvent {
        kind: 6,
        x: 0.25,
        y: 1.0,
        delta_x: -3.5,
        delta_y: 12.0,
        modifiers: 0b1000,
        ..Default::default()
    };
    assert_eq!(send_input(viewer.0, &scroll), 0);
    assert_eq!(send_control(viewer.0, &control(3, 7)), 0);
    assert_eq!(send_control(viewer.0, &control(5, 0)), 0);
    let (status, message) = typed(host.0, &mut [], 1000);
    assert_eq!((status, message.kind), (0, INPUT));
    let input = message.input;
    assert_eq!(
        (
            input.kind,
            input.x,
            input.y,
            input.delta_x,
            input.delta_y,
            input.modifiers
        ),
        (6, 0.25, 1.0, -3.5, 12.0, 0b1000)
    );
    assert_eq!(typed(host.0, &mut [], 1000).1.control.ping_id, 7);
    assert_eq!(typed(host.0, &mut [], 1000).1.control.kind, 5);
}

#[test]
fn misdirected_or_invalid_sends_fail_without_closing() {
    let (viewer, host) = pair();
    assert_eq!(
        send_video(viewer.0, &frame(IDR, true, 1)),
        Error::Invalid as i32,
        "viewers never send video"
    );
    assert_eq!(
        send_input(host.0, &key_event(1, 0)),
        Error::Invalid as i32,
        "hosts never send input"
    );
    assert_eq!(
        send_control(host.0, &control(3, 1)),
        Error::Invalid as i32,
        "hosts never ping"
    );
    assert_eq!(
        send_control(viewer.0, &geometry(1)),
        Error::Invalid as i32,
        "viewers never send geometry"
    );
    let mut invalid_geometry = geometry(1);
    invalid_geometry.geometry.pixel_width = 1921;
    assert_eq!(
        send_control(host.0, &invalid_geometry),
        Error::Invalid as i32
    );
    assert_eq!(
        send_input(viewer.0, &key_event(1, 128)),
        Error::Invalid as i32
    );
    let mut reserved = key_event(1, 0);
    reserved.reserved[0] = 1;
    assert_eq!(send_input(viewer.0, &reserved), Error::Invalid as i32);
    assert_eq!(
        send_video(host.0, &frame(IDR, false, 1)),
        Error::Invalid as i32,
        "forged keyframe flag"
    );
    assert!(!is_closed(viewer.0) && !is_closed(host.0));
    assert_eq!(send_control(host.0, &geometry(1)), 0);
    assert_eq!(typed(viewer.0, &mut vec![0; MAX_VIDEO], 1000).0, 0);
}

#[test]
fn peer_protocol_violations_close_the_receiving_session() {
    let valid_video = crate::video::tests::frame(IDR, true).encode().unwrap();
    // Video before geometry, a malformed typed payload, and a malformed packet.
    for (kind, bytes) in [
        (VIDEO, valid_video.clone()),
        (CONTROL, vec![1; 51]),
        (VIDEO, valid_video[..40].to_vec()),
    ] {
        let (viewer, host) = pair();
        if bytes.len() == 40 {
            assert_eq!(send_control(host.0, &geometry(1)), 0);
            assert_eq!(typed(viewer.0, &mut vec![0; MAX_VIDEO], 1000).0, 0);
        }
        assert_eq!(send(host.0, kind, &bytes), 0);
        let mut buffer = vec![0; MAX_VIDEO];
        assert_eq!(typed(viewer.0, &mut buffer, 1000).0, Error::Protocol as i32);
        assert!(is_closed(viewer.0));
        assert!(
            buffer.iter().all(|byte| *byte == 0),
            "no rejected plaintext remains"
        );
    }
}

#[test]
fn viewer_control_flood_is_rate_limited() {
    let (viewer, host) = pair();
    let mut buffer = vec![0; MAX_VIDEO];
    assert_eq!(send_control(host.0, &geometry(1)), 0);
    for _ in 0..32 {
        assert_eq!(send_control(host.0, &control(4, 1)), 0);
    }
    for _ in 0..32 {
        assert_eq!(typed(viewer.0, &mut buffer, 1000).0, 0);
    }
    assert_eq!(
        typed(viewer.0, &mut buffer, 1000).0,
        Error::RateLimited as i32
    );
    assert!(is_closed(viewer.0));
}

#[test]
fn hosts_skip_closely_spaced_pings_and_stall_idle_viewers() {
    let (viewer, host) = pair();
    assert_eq!(send_control(viewer.0, &control(3, 1)), 0);
    assert_eq!(send_control(viewer.0, &control(3, 2)), 0);
    assert_eq!(typed(host.0, &mut [], 1000).1.control.ping_id, 1);
    assert_eq!(
        typed(host.0, &mut [], 50).0,
        Error::Timeout as i32,
        "the second ping is consumed, not returned"
    );
    assert!(!is_closed(host.0));
    session(host.0)
        .unwrap()
        .receive
        .lock()
        .unwrap()
        .policy
        .idle_limit = Duration::from_millis(60);
    std::thread::sleep(Duration::from_millis(70));
    assert_eq!(typed(host.0, &mut [], 30).0, Error::Stalled as i32);
    assert!(is_closed(host.0));
}

fn events(capacity: usize) -> Vec<MLInputEvent> {
    vec![MLInputEvent::default(); capacity]
}

#[test]
fn input_state_abi_stages_commits_releases_and_stops() {
    let state = ml_input_state_new();
    let mut out = events(131);
    let mut count = 99;
    let down = key_event(1, 4);
    unsafe {
        assert_eq!(
            ml_input_state_accept(
                state,
                &down,
                1.0,
                out.as_mut_ptr(),
                130,
                &mut count,
                std::ptr::null_mut()
            ),
            Error::Invalid as i32
        );
        assert_eq!(count, 0);
        assert_eq!(
            ml_input_state_accept(
                state,
                &down,
                1.0,
                out.as_mut_ptr(),
                131,
                &mut count,
                std::ptr::null_mut()
            ),
            0
        );
        assert_eq!((count, out[0].kind, out[0].key_code), (1, 1, 4));
        assert_eq!(
            ml_input_state_release_all(state, out.as_mut_ptr(), 131, &mut count),
            0
        );
        assert_eq!(count, 0, "uncommitted presses are not held");
        assert_eq!(
            ml_input_state_accept(
                state,
                &down,
                1.0,
                out.as_mut_ptr(),
                131,
                &mut count,
                std::ptr::null_mut()
            ),
            0
        );
        assert_eq!(ml_input_state_commit(state), 0);
        let click = MLInputEvent {
            kind: 4,
            button: 1,
            click_count: 1,
            x: 0.5,
            y: 0.5,
            ..Default::default()
        };
        let mut held = 99;
        assert_eq!(
            ml_input_state_accept(
                state,
                &click,
                1.0,
                out.as_mut_ptr(),
                131,
                &mut count,
                &mut held
            ),
            0
        );
        assert_eq!(
            (count, held),
            (1, 0b010),
            "held buttons describe the staged transition"
        );
        assert_eq!(
            ml_input_state_accept(
                state,
                &down,
                1.1,
                out.as_mut_ptr(),
                131,
                &mut count,
                std::ptr::null_mut()
            ),
            0
        );
        assert_eq!(count, 0, "duplicate press");
        let mut invalid = down;
        invalid.key_code = 200;
        assert_eq!(
            ml_input_state_accept(
                state,
                &invalid,
                1.0,
                out.as_mut_ptr(),
                131,
                &mut count,
                std::ptr::null_mut()
            ),
            Error::Invalid as i32
        );
        assert_eq!(
            ml_input_state_stop(state, out.as_mut_ptr(), 131, &mut count),
            0
        );
        assert_eq!((count, out[0].kind, out[0].key_code), (1, 2, 4));
        assert_eq!(
            ml_input_state_accept(
                state,
                &down,
                2.0,
                out.as_mut_ptr(),
                131,
                &mut count,
                std::ptr::null_mut()
            ),
            Error::Closed as i32
        );
        ml_input_state_free(state);
        ml_input_state_free(std::ptr::null_mut());
    }
}

fn text<const N: usize>(value: &[c_char; N]) -> String {
    let end = value.iter().position(|byte| *byte == 0).unwrap();
    String::from_utf8(value[..end].iter().map(|byte| *byte as u8).collect()).unwrap()
}
fn empty_code() -> MLPairingCode {
    MLPairingCode {
        address: [0; ML_TEXT_CAPACITY],
        name: [0; ML_TEXT_CAPACITY],
        peer_id: [0; ML_PEER_ID_CAPACITY],
        public_key: [0; 32],
        secret: [0; 32],
    }
}

#[test]
fn pairing_abi_round_trips_codes_and_credentials() {
    let (_, public, psk) = identity();
    let mut code = empty_code();
    let name = CString::new("Pat’s\u{200d} Mac\n").unwrap();
    let status = unsafe {
        ml_pairing_code_for_host(
            c"Studio.local".as_ptr(),
            name.as_ptr(),
            public.as_ptr(),
            psk.as_ptr(),
            &mut code,
        )
    };
    assert_eq!(status, 0);
    assert_eq!(
        (text(&code.address), text(&code.name), code.secret),
        ("studio.local".into(), "Pat’s Mac".into(), psk)
    );
    assert_eq!(text(&code.peer_id).len(), 64);
    let mut encoded = vec![0 as c_char; ML_PAIRING_CODE_CAPACITY];
    assert_eq!(
        unsafe { ml_pairing_code_encode(&code, encoded.as_mut_ptr(), 2048) },
        Error::Invalid as i32
    );
    assert_eq!(
        unsafe { ml_pairing_code_encode(&code, encoded.as_mut_ptr(), encoded.len()) },
        0
    );
    let mut parsed = empty_code();
    assert_eq!(
        unsafe { ml_pairing_code_parse(encoded.as_ptr(), &mut parsed) },
        0
    );
    assert_eq!(
        (text(&parsed.peer_id), parsed.public_key, parsed.secret),
        (text(&code.peer_id), public, psk)
    );
    let mut credential = vec![0; ML_CREDENTIAL_CAPACITY];
    let mut length = 0;
    assert_eq!(
        unsafe {
            ml_pairing_credential_encode(
                &code,
                credential.as_mut_ptr(),
                credential.len(),
                &mut length,
            )
        },
        0
    );
    let mut decoded = empty_code();
    assert_eq!(
        unsafe { ml_pairing_credential_decode(credential.as_ptr(), length, &mut decoded) },
        0
    );
    assert_eq!(
        (text(&decoded.name), decoded.secret),
        (text(&code.name), psk)
    );
    assert_eq!(
        unsafe { ml_pairing_code_parse(c"MLP1.invalid".as_ptr(), &mut decoded) },
        Error::Invalid as i32
    );
    assert_eq!(
        (decoded.secret, text(&decoded.name)),
        ([0; 32], String::new()),
        "failed parses clear outputs"
    );
    let mut tampered = empty_code();
    assert_eq!(
        unsafe { ml_pairing_code_parse(encoded.as_ptr(), &mut tampered) },
        0
    );
    tampered.name[0] = 0x0a;
    assert_eq!(
        unsafe { ml_pairing_code_encode(&tampered, encoded.as_mut_ptr(), encoded.len()) },
        Error::Invalid as i32
    );
    let mut normalized = vec![0 as c_char; ML_TEXT_CAPACITY];
    assert_eq!(
        unsafe {
            ml_address_normalize(c"[::1]".as_ptr(), normalized.as_mut_ptr(), normalized.len())
        },
        0
    );
    assert_eq!(
        text(&<[c_char; ML_TEXT_CAPACITY]>::try_from(normalized.as_slice()).unwrap()),
        "::1"
    );
    assert_eq!(
        unsafe {
            ml_address_normalize(
                c"host:5900".as_ptr(),
                normalized.as_mut_ptr(),
                normalized.len(),
            )
        },
        Error::Invalid as i32
    );
}

#[test]
fn peers_abi_loads_remembers_and_imports() {
    let directory = std::env::temp_dir().join(format!("maclink-peers-abi-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    let path = CString::new(directory.to_str().unwrap()).unwrap();
    let mut peers: Vec<MLPeer> = (0..32)
        .map(|_| MLPeer {
            id: [0; 65],
            name: [0; 256],
            address: [0; 256],
        })
        .collect();
    let mut count = 99;
    let legacy = br#"[{"id":"0000000000000000000000000000000000000000000000000000000000000001","name":"Old Mac","address":"old.local"}]"#;
    let mut imported = 99;
    unsafe {
        assert_eq!(
            ml_peers_load(path.as_ptr(), peers.as_mut_ptr(), 31, &mut count),
            Error::Invalid as i32
        );
        assert_eq!(
            ml_peers_load(path.as_ptr(), peers.as_mut_ptr(), 32, &mut count),
            0
        );
        assert_eq!(count, 0);
        assert_eq!(
            ml_peers_import_legacy(path.as_ptr(), legacy.as_ptr(), legacy.len(), &mut imported),
            0
        );
        assert_eq!(imported, 1);
        let (_, public, psk) = identity();
        let mut code = empty_code();
        assert_eq!(
            ml_pairing_code_for_host(
                c"studio.local".as_ptr(),
                c"Studio".as_ptr(),
                public.as_ptr(),
                psk.as_ptr(),
                &mut code
            ),
            0
        );
        let mut saved = MLPeer {
            id: [0; 65],
            name: [0; 256],
            address: [0; 256],
        };
        assert_eq!(
            ml_peers_remember(path.as_ptr(), &code, c"10.0.0.2".as_ptr(), &mut saved),
            0
        );
        assert_eq!(text(&saved.id), text(&code.peer_id));
        assert_eq!(
            ml_peers_remember(
                path.as_ptr(),
                &code,
                c"http://x".as_ptr(),
                std::ptr::null_mut()
            ),
            Error::Invalid as i32
        );
        assert_eq!(
            ml_peers_load(path.as_ptr(), peers.as_mut_ptr(), 32, &mut count),
            0
        );
        assert_eq!(count, 2);
        assert_eq!(
            (text(&peers[0].name), text(&peers[0].address)),
            ("Studio".into(), "10.0.0.2".into())
        );
        assert_eq!(text(&peers[1].name), "Old Mac");
        assert_eq!(ml_peers_forget(path.as_ptr(), code.peer_id.as_ptr()), 0);
        assert_eq!(
            ml_peers_forget(path.as_ptr(), std::ptr::null()),
            Error::Invalid as i32
        );
        assert_eq!(
            ml_peers_load(path.as_ptr(), peers.as_mut_ptr(), 32, &mut count),
            0
        );
        assert_eq!((count, text(&peers[0].name)), (1, "Old Mac".into()));
        let empty = CString::new("").unwrap();
        assert_eq!(
            ml_peers_load(empty.as_ptr(), peers.as_mut_ptr(), 32, &mut count),
            Error::Invalid as i32
        );
    }
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn accepted_connections_get_a_bounded_handshake_grace() {
    // A viewer whose connection lands at the end of the host's accept window
    // must still finish authenticating instead of being dropped mid-handshake.
    let (private, public, psk) = identity();
    let listener = bind(&private, &psk);
    let id = listener.0;
    let raw = TcpStream::connect(("127.0.0.1", ml_session_listener_port(id))).unwrap();
    let accepting = std::thread::spawn(move || {
        let mut handle = 0;
        let status = unsafe { ml_session_accept(id, 50, &mut handle) };
        (status, Owned(handle))
    });
    std::thread::sleep(Duration::from_millis(120)); // past the accept deadline
    let mut noise = builder()
        .unwrap()
        .remote_public_key(&public)
        .unwrap()
        .psk(0, &psk)
        .unwrap()
        .prologue(PROLOGUE)
        .unwrap()
        .build_initiator()
        .unwrap();
    let end = deadline(2000).unwrap();
    let (mut record, mut payload) = ([0; 1024], [0; 1024]);
    let count = noise.write_message(HANDSHAKE_PAYLOAD, &mut record).unwrap();
    write_record(&raw, &record[..count], end).unwrap();
    let size = read_record(&raw, &mut record, end, &mut 0).unwrap();
    noise.read_message(&record[..size], &mut payload).unwrap();
    let crypto = noise.into_stateless_transport_mode().unwrap();
    let count = crypto
        .write_message(0, b"client-ready/1", &mut record)
        .unwrap();
    write_record(&raw, &record[..count], end).unwrap();
    let size = read_record(&raw, &mut record, end, &mut 0).unwrap();
    let count = crypto
        .read_message(0, &record[..size], &mut payload)
        .unwrap();
    assert_eq!(&payload[..count], b"server-ready/1");
    let (status, host) = accepting.join().unwrap();
    assert_eq!(status, 0);
    assert_ne!(host.0, 0);
}

fn stats_message(values: &[(u8, f64)]) -> MLTelemetryMessage {
    let mut message = MLTelemetryMessage {
        kind: 1,
        count: values.len() as u8,
        ..Default::default()
    };
    for (slot, (metric, value)) in message.metrics.iter_mut().zip(values) {
        *slot = MLMetric {
            metric: *metric,
            reserved: [0; 7],
            value: *value,
        };
    }
    message
}

#[test]
fn telemetry_flows_both_ways_but_only_viewers_tune() {
    let (viewer, host) = pair();
    let mut buffer = vec![0; MAX_VIDEO];
    let stats = stats_message(&[(1, 42.0), (7, 23.5)]);
    assert_eq!(
        unsafe { ml_session_send_telemetry(host.0, &stats, 1000) },
        0
    );
    let (status, message) = typed(viewer.0, &mut buffer, 1000);
    assert_eq!(
        (
            status,
            message.kind,
            message.telemetry.kind,
            message.telemetry.count
        ),
        (0, TELEMETRY, 1, 2)
    );
    assert_eq!(
        (
            message.telemetry.metrics[1].metric,
            message.telemetry.metrics[1].value
        ),
        (7, 23.5)
    );
    let tune = MLTelemetryMessage {
        kind: 2,
        tuning: MLTuning {
            fps: 30,
            bitrate_kbps: 12_000,
            ..Default::default()
        },
        ..Default::default()
    };
    assert_eq!(
        unsafe { ml_session_send_telemetry(host.0, &tune, 1000) },
        Error::Invalid as i32,
        "hosts never tune"
    );
    assert_eq!(
        unsafe { ml_session_send_telemetry(viewer.0, &tune, 1000) },
        0
    );
    assert_eq!(
        unsafe { ml_session_send_telemetry(viewer.0, &stats, 1000) },
        0
    );
    let (status, message) = typed(host.0, &mut [], 1000);
    assert_eq!(
        (
            status,
            message.telemetry.kind,
            message.telemetry.tuning.fps,
            message.telemetry.tuning.bitrate_kbps
        ),
        (0, 2, 30, 12_000)
    );
    assert_eq!(typed(host.0, &mut [], 1000).1.telemetry.count, 2);
    let mut invalid = stats;
    invalid.metrics[0].value = f64::NAN;
    let mut unknown = stats;
    unknown.metrics[0].metric = 99;
    let mut too_many = stats;
    too_many.count = 33;
    let mut duplicate = stats;
    duplicate.metrics[1].metric = 1;
    let empty_tune = MLTelemetryMessage {
        kind: 2,
        ..Default::default()
    };
    let wide = MLTelemetryMessage {
        kind: 2,
        tuning: MLTuning {
            max_width: 5120,
            ..Default::default()
        },
        ..Default::default()
    };
    for message in [invalid, unknown, too_many, duplicate, empty_tune, wide] {
        assert_eq!(
            unsafe { ml_session_send_telemetry(viewer.0, &message, 1000) },
            Error::Invalid as i32
        );
    }
    assert!(
        !is_closed(viewer.0) && !is_closed(host.0),
        "invalid local telemetry leaves the session open"
    );
}

#[test]
fn local_telemetry_abi_serves_snapshots_and_takes_tuning() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;
    let folder = format!("/tmp/mltf-{}", std::process::id());
    let _ = std::fs::remove_dir_all(&folder);
    let path = CString::new(folder.clone()).unwrap();
    let mut tuning = MLTuning::default();
    assert_eq!(
        unsafe { ml_telemetry_take_tuning(&mut tuning) },
        Error::Closed as i32,
        "nothing serves before start"
    );
    assert_eq!(unsafe { ml_telemetry_start(path.as_ptr()) }, 0);
    assert_eq!(
        unsafe { ml_telemetry_start(path.as_ptr()) },
        0,
        "start is idempotent"
    );
    let client = UnixStream::connect(format!("{folder}/telemetry/telemetry.sock")).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let mut reader = BufReader::new(client.try_clone().unwrap());
    let mut writer = client;
    writer
        .write_all(b"{\"tune\":{\"fps\":24,\"in_flight\":1}}\n")
        .unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert!(line.contains("ack"), "{line}");
    assert_eq!(unsafe { ml_telemetry_take_tuning(&mut tuning) }, 1);
    assert_eq!(
        (tuning.fps, tuning.in_flight, tuning.bitrate_kbps),
        (24, 1, 0)
    );
    let taken = tuning;
    assert_eq!(unsafe { ml_telemetry_take_tuning(&mut tuning) }, 0);
    assert_eq!(tuning.fps, 0, "an empty take clears its output");
    let mut defaults = MLTuning::default();
    assert_eq!(unsafe { ml_tuning_defaults(&mut defaults) }, 0);
    let mut merged = MLTuning::default();
    assert_eq!(
        unsafe { ml_tuning_merge(&defaults, &taken, &mut merged) },
        0
    );
    assert_eq!(
        (merged.fps, merged.in_flight, merged.bitrate_kbps),
        (24, 1, 25_000)
    );
    let mut snapshot = MLTelemetrySnapshot {
        role: 2,
        local_count: 1,
        session_seconds: 3.5,
        peer_age_seconds: -1.0,
        tuning: merged,
        last_end_age_seconds: 4.0,
        ..Default::default()
    };
    for (slot, byte) in snapshot.last_end.iter_mut().zip(b"Session closed") {
        *slot = *byte as c_char;
    }
    snapshot.local[0] = MLMetric {
        metric: 38,
        reserved: [0; 7],
        value: 7.5,
    };
    assert_eq!(unsafe { ml_telemetry_publish(&snapshot) }, 0);
    line.clear();
    reader.read_line(&mut line).unwrap();
    assert!(
        line.contains(r#""rtt_ms":7.5"#)
            && line.contains(r#""peer_age_s":null"#)
            && line.contains(r#""fps":24"#)
            && line.contains(r#""last_end":{"age_s":4.0,"reason":"Session closed"}"#),
        "{line}"
    );
    let mut bad = snapshot;
    bad.role = 9;
    assert_eq!(unsafe { ml_telemetry_publish(&bad) }, Error::Invalid as i32);
    assert_eq!(ml_telemetry_stop(), 0);
    assert_eq!(
        unsafe { ml_telemetry_publish(&snapshot) },
        Error::Closed as i32
    );
    assert!(!std::path::Path::new(&format!("{folder}/telemetry/telemetry.sock")).exists());
    let _ = std::fs::remove_dir_all(folder);
}

#[test]
fn reconnect_budget_and_local_shortcuts_cross_the_c_abi() {
    let delays: Vec<i32> = (0..=ML_RECONNECT_ATTEMPTS + 1)
        .map(|attempt| ml_reconnect_delay_ms(attempt))
        .collect();
    assert_eq!(
        delays,
        [
            Error::Invalid as i32,
            500,
            1000,
            2000,
            4000,
            8000,
            Error::Invalid as i32
        ]
    );
    assert_eq!(ml_input_keeps_local(53, 8 | 4), 1); // ⌘⌥Esc
    assert_eq!(ml_input_keeps_local(48, 8), 0); // ⌘-Tab goes to the remote Mac
}

fn clipboard_item(kind: u8, bytes: &[u8]) -> MLClipboardItem {
    MLClipboardItem {
        bytes: bytes.as_ptr(),
        length: bytes.len(),
        kind,
        reserved: [0; 7],
    }
}

#[test]
fn clipboards_cross_both_ways_in_the_callers_buffer() {
    const PNG: &[u8] = b"\x89PNG\r\n\x1a\nimage";
    let (viewer, host) = pair();
    let text = "Copied on the viewer ✓".as_bytes();
    let items = [clipboard_item(1, text), clipboard_item(3, PNG)];
    assert_eq!(
        unsafe { ml_clipboard_validate(items.as_ptr(), items.len()) },
        0
    );
    assert_eq!(
        unsafe { ml_session_send_clipboard(viewer.0, items.as_ptr(), items.len(), 1000) },
        0
    );
    let mut buffer = vec![0; ML_SESSION_MAX_MESSAGE];
    let (status, message) = typed(host.0, &mut buffer, 1000);
    assert_eq!(
        (status, message.kind, message.clipboard.count),
        (0, CLIPBOARD, 2)
    );
    let range = |index: usize| {
        let item = message.clipboard.items[index];
        (
            item.kind,
            buffer[item.offset..item.offset + item.length].to_vec(),
        )
    };
    assert_eq!(range(0), (1, text.to_vec()));
    assert_eq!(range(1), (3, PNG.to_vec()));

    // The largest allowed clipboard crosses in the other direction.
    let sender = host.0;
    let sending = std::thread::spawn(move || {
        let largest = vec![b'z'; ML_CLIPBOARD_MAX_BYTES];
        let item = [clipboard_item(1, &largest)];
        unsafe { ml_session_send_clipboard(sender, item.as_ptr(), 1, 5000) }
    });
    let (status, message) = typed(viewer.0, &mut buffer, 5000);
    assert_eq!(sending.join().unwrap(), 0);
    assert_eq!(
        (status, message.kind, message.clipboard.items[0].length),
        (0, CLIPBOARD, ML_CLIPBOARD_MAX_BYTES)
    );
    assert!(
        buffer[message.clipboard.items[0].offset..][..ML_CLIPBOARD_MAX_BYTES]
            .iter()
            .all(|byte| *byte == b'z')
    );
}

#[test]
fn invalid_clipboards_fail_before_sending_and_leave_the_session_open() {
    let (viewer, host) = pair();
    let over = vec![b'a'; ML_CLIPBOARD_MAX_BYTES + 1];
    let rtf = b"{\\rtf1 x}";
    for items in [
        vec![],
        vec![clipboard_item(1, b"")],
        vec![clipboard_item(4, b"a")],
        vec![clipboard_item(1, &over)],
        vec![clipboard_item(1, b"\xff")],
        vec![clipboard_item(2, b"plain")],
        vec![clipboard_item(2, rtf), clipboard_item(1, b"a")],
        vec![clipboard_item(1, b"a"), clipboard_item(1, b"b")],
        vec![
            clipboard_item(1, b"a"),
            clipboard_item(2, rtf),
            clipboard_item(3, b"no"),
            clipboard_item(1, b"c"),
        ],
    ] {
        let pointer = if items.is_empty() {
            std::ptr::null()
        } else {
            items.as_ptr()
        };
        assert_eq!(
            unsafe { ml_clipboard_validate(pointer, items.len()) },
            Error::Invalid as i32
        );
        assert_eq!(
            unsafe { ml_session_send_clipboard(viewer.0, pointer, items.len(), 1000) },
            Error::Invalid as i32
        );
    }
    assert!(!is_closed(viewer.0));
    let good = [clipboard_item(2, rtf)];
    assert_eq!(
        unsafe { ml_session_send_clipboard(viewer.0, good.as_ptr(), 1, 1000) },
        0
    );
    let mut buffer = vec![0; ML_SESSION_MAX_MESSAGE];
    assert_eq!(typed(host.0, &mut buffer, 1000).1.kind, CLIPBOARD);
}

#[test]
fn a_malformed_clipboard_closes_the_receiver_and_clears_it() {
    let (viewer, host) = pair();
    // Authenticated but malformed: Text whose bytes are not UTF-8.
    let body = [1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 2, 0xff, 0xfe];
    inject(
        viewer.0,
        &encrypted(
            viewer.0,
            0,
            &plain(CLIPBOARD, body.len() as u32, 0, 0, &body),
        ),
    );
    let result = receive(host.0, 4096, 1000);
    assert_eq!(result.0, 0, "the untyped path only frames");
    let (viewer, host) = pair();
    inject(
        viewer.0,
        &encrypted(
            viewer.0,
            0,
            &plain(CLIPBOARD, body.len() as u32, 0, 0, &body),
        ),
    );
    let mut buffer = vec![0x55; 4096];
    assert_eq!(typed(host.0, &mut buffer, 1000).0, Error::Protocol as i32);
    assert!(
        buffer[..body.len()].iter().all(|byte| *byte == 0),
        "rejected plaintext is cleared"
    );
    assert!(is_closed(host.0));
}

const TEST_CAPABILITIES: u64 =
    ML_CAPABILITY_HEVC_444 | ML_CAPABILITY_VIRTUAL_DISPLAY | ML_CAPABILITY_CURSOR | 1 << 40; // plus a bit no build knows // plus a bit no build knows
fn hello(id: u64) -> u64 {
    let mut buffer = vec![0; 4096];
    let (status, message) = typed(id, &mut buffer, 2000);
    assert_eq!(
        (status, message.kind, message.control.kind),
        (0, CONTROL, 6)
    );
    message.control.ping_id
}

#[test]
fn handshake_versions_are_strictly_formatted() {
    use crate::transport::handshake_version;
    assert_eq!(handshake_version(b"maclink-session/4"), Some(4));
    assert_eq!(handshake_version(b"maclink-session/12"), Some(12));
    for bad in [
        &b"maclink-session/"[..],
        b"maclink-session/05",
        b"maclink-session/5a",
        b"maclink-session/-5",
        b"maclink-session/99999",
        b"other-session/5",
        b"maclink-session/5\0",
    ] {
        assert_eq!(handshake_version(bad), None, "{bad:?}");
    }
}

#[test]
fn protocol_5_sessions_start_with_each_sides_capabilities() {
    ml_capabilities_set(TEST_CAPABILITIES);
    let (viewer, host) = pair_version(5);
    assert_eq!(
        (
            ml_session_protocol_version(viewer.0),
            ml_session_protocol_version(host.0)
        ),
        (5, 5)
    );
    assert_eq!(hello(host.0), TEST_CAPABILITIES);
    assert_eq!(hello(viewer.0), TEST_CAPABILITIES);
    let mut peer = 0;
    assert_eq!(
        unsafe { ml_session_peer_capabilities(host.0, &mut peer) },
        0
    );
    assert_eq!(
        peer, TEST_CAPABILITIES,
        "unknown bits are kept, not rejected"
    );
    // A second Hello is a protocol violation.
    assert_eq!(send_control(viewer.0, &control(6, 1)), 0);
    let mut buffer = vec![0; 4096];
    assert_eq!(typed(host.0, &mut buffer, 2000).0, Error::Protocol as i32);
}

#[test]
fn older_viewers_get_protocol_4_from_newer_hosts() {
    let (viewer, host) = pair_version(4);
    assert_eq!(
        (
            ml_session_protocol_version(viewer.0),
            ml_session_protocol_version(host.0)
        ),
        (4, 4)
    );
    let mut peer = 7;
    assert_eq!(
        unsafe { ml_session_peer_capabilities(host.0, &mut peer) },
        0
    );
    assert_eq!(peer, 0);
    assert_eq!(
        send_control(viewer.0, &control(6, 1)),
        Error::Invalid as i32,
        "no Hello in protocol 4"
    );
    assert_eq!(send_input(viewer.0, &key_event(1, 0)), 0);
    let mut buffer = vec![0; 4096];
    assert_eq!(
        typed(host.0, &mut buffer, 2000).1.kind,
        INPUT,
        "the first message is ordinary input"
    );
}

#[test]
fn newer_viewers_fall_back_for_hosts_before_protocol_5() {
    ml_capabilities_set(TEST_CAPABILITIES);
    crate::transport::TEST_OFFER.with(|value| value.set(5));
    let (private, public, psk) = identity();
    let listener = bind(&private, &psk);
    let id = listener.0;
    // Imitate a preview 4-8 host: exactly protocol 4, anything else refused.
    crate::transport::listener(id)
        .unwrap()
        .exact_version
        .store(4, Ordering::Release);
    let accept = std::thread::spawn(move || {
        let mut host = 0;
        let first = unsafe { ml_session_accept(id, 5000, &mut host) };
        assert_eq!(first, Error::Protocol as i32, "the newer offer is refused");
        assert_eq!(unsafe { ml_session_accept(id, 5000, &mut host) }, 0);
        Owned(host)
    });
    let mut viewer = 0;
    assert_eq!(
        connect(
            ml_session_listener_port(id),
            &public,
            &psk,
            5000,
            &mut viewer
        ),
        0
    );
    let (viewer, host) = (Owned(viewer), accept.join().unwrap());
    assert_eq!(
        (
            ml_session_protocol_version(viewer.0),
            ml_session_protocol_version(host.0)
        ),
        (4, 4)
    );
    assert_eq!(send_input(viewer.0, &key_event(1, 0)), 0);
    let mut buffer = vec![0; 4096];
    assert_eq!(typed(host.0, &mut buffer, 2000).1.kind, INPUT);
}

fn hevc(data: &[u8], keyframe: bool, sequence: u64) -> MLVideoFrame {
    use crate::video::tests::{HEVC_PPS, HEVC_SPS, VPS};
    let mut value = frame(data, keyframe, sequence);
    value.header.codec = ML_CODEC_HEVC;
    (value.vps, value.vps_length) = (VPS.as_ptr(), VPS.len());
    (value.sps, value.sps_length) = (HEVC_SPS.as_ptr(), HEVC_SPS.len());
    (value.pps, value.pps_length) = (HEVC_PPS.as_ptr(), HEVC_PPS.len());
    value
}

#[test]
fn hevc_reaches_only_viewers_that_announced_it() {
    use crate::video::tests::{HEVC_IDR, HEVC_SPS, VPS};
    ml_capabilities_set(TEST_CAPABILITIES);
    let (viewer, host) = pair_version(5);
    assert_eq!(
        (hello(host.0), hello(viewer.0)),
        (TEST_CAPABILITIES, TEST_CAPABILITIES)
    );
    assert_eq!(send_control(host.0, &geometry(1)), 0);
    assert_eq!(send_video(host.0, &hevc(HEVC_IDR, true, 0)), 0);
    let mut buffer = vec![0; ML_SESSION_MAX_MESSAGE];
    assert_eq!(typed(viewer.0, &mut buffer, 2000).1.kind, CONTROL);
    let (status, message) = typed(viewer.0, &mut buffer, 2000);
    assert_eq!(
        (status, message.kind, message.video.header.codec),
        (0, VIDEO, ML_CODEC_HEVC)
    );
    let packet = message.video;
    assert_eq!(&buffer[packet.vps_offset..][..packet.vps_length], VPS);
    assert_eq!(&buffer[packet.sps_offset..][..packet.sps_length], HEVC_SPS);
    assert_eq!(
        unsafe { ml_video_hevc_chroma_format(HEVC_SPS.as_ptr(), HEVC_SPS.len()) },
        3
    );

    // Protocol 4 has no capabilities, so HEVC is refused before sending.
    let (_viewer, old_host) = pair_version(4);
    assert_eq!(
        send_video(old_host.0, &hevc(HEVC_IDR, true, 0)),
        Error::Invalid as i32
    );
    assert!(!is_closed(old_host.0));
    assert_eq!(
        send_video(old_host.0, &frame(IDR, true, 0)),
        0,
        "H.264 still flows"
    );
}

fn display_request(width: u32, height: u32, scale: u32) -> MLControlMessage {
    MLControlMessage {
        kind: 7,
        geometry: MLDisplayGeometry {
            width: width.into(),
            height: height.into(),
            pixel_width: width * scale,
            pixel_height: height * scale,
            ..Default::default()
        },
        ..Default::default()
    }
}

#[test]
fn viewers_ask_capable_hosts_for_a_display_their_size() {
    ml_capabilities_set(TEST_CAPABILITIES);
    let (viewer, host) = pair_version(5);
    assert_eq!(
        (hello(host.0), hello(viewer.0)),
        (TEST_CAPABILITIES, TEST_CAPABILITIES)
    );
    assert_eq!(send_control(viewer.0, &display_request(1512, 916, 2)), 0);
    assert_eq!(
        send_control(host.0, &display_request(1512, 916, 2)),
        Error::Invalid as i32,
        "hosts never ask"
    );
    let mut buffer = vec![0; 4096];
    let (status, message) = typed(host.0, &mut buffer, 2000);
    assert_eq!(
        (status, message.kind, message.control.kind),
        (0, CONTROL, 7)
    );
    let geometry = message.control.geometry;
    assert_eq!(
        (
            geometry.width,
            geometry.height,
            geometry.pixel_width,
            geometry.pixel_height
        ),
        (1512.0, 916.0, 3024, 1832)
    );
    // Before a capable host's Hello, or in protocol 4, the request is refused locally.
    let (old_viewer, _old_host) = pair_version(4);
    assert_eq!(
        send_control(old_viewer.0, &display_request(1512, 916, 2)),
        Error::Invalid as i32
    );
    assert!(!is_closed(old_viewer.0));
}

#[test]
fn hosts_send_pointer_shapes_to_viewers_that_draw_them() {
    const PNG: &[u8] = b"\x89PNG\r\n\x1a\ncursor";
    ml_capabilities_set(TEST_CAPABILITIES);
    let (viewer, host) = pair_version(5);
    assert_eq!(
        (hello(host.0), hello(viewer.0)),
        (TEST_CAPABILITIES, TEST_CAPABILITIES)
    );
    let send = |id: u64, png: &[u8]| unsafe {
        ml_session_send_cursor(id, 9, 18, 4, 9, png.as_ptr(), png.len(), 1000)
    };
    assert_eq!(send(host.0, PNG), 0);
    assert_eq!(
        send(viewer.0, PNG),
        Error::Invalid as i32,
        "viewers never send cursors"
    );
    assert_eq!(send(host.0, b"GIF89a"), Error::Invalid as i32);
    let mut buffer = vec![0; ML_SESSION_MAX_MESSAGE];
    let (status, message) = typed(viewer.0, &mut buffer, 2000);
    assert_eq!((status, message.kind), (0, crate::policy::CURSOR));
    let cursor = message.cursor;
    assert_eq!(
        (
            cursor.width,
            cursor.height,
            cursor.hotspot_x,
            cursor.hotspot_y
        ),
        (9, 18, 4, 9)
    );
    assert_eq!(&buffer[cursor.png_offset..][..cursor.png_length], PNG);
    // Twenty per second at most; the twenty-first ends the session.
    for _ in 0..20 {
        assert_eq!(send(host.0, PNG), 0);
    }
    assert_eq!(send(host.0, PNG), 0);
    let mut status = 0;
    for _ in 0..21 {
        status = typed(viewer.0, &mut buffer, 2000).0;
        if status != 0 {
            break;
        }
    }
    assert_eq!(status, Error::RateLimited as i32);
    // Protocol 4 viewers announce nothing, so cursors are refused before sending.
    let (_old_viewer, old_host) = pair_version(4);
    assert_eq!(send(old_host.0, PNG), Error::Invalid as i32);
    assert!(!is_closed(old_host.0));
}
