//! Bounded Annex B -> Mooring AVCC adapter. x264 must emit access unit delimiters.
use mooring_session::ffi::*;
const LIMIT: usize = 12 * 1024 * 1024 - 16384;
#[derive(Default)]
pub struct Parser {
    pending: Vec<u8>,
    sps: Vec<u8>,
    pps: Vec<u8>,
    unit: Vec<u8>,
    slices: bool,
    key: bool,
    sequence: u64,
}
fn start(bytes: &[u8]) -> Option<(usize, usize)> {
    (0..bytes.len().saturating_sub(2)).find_map(|i| {
        if bytes[i..].starts_with(&[0, 0, 0, 1]) {
            Some((i, 4))
        } else if bytes[i..].starts_with(&[0, 0, 1]) {
            Some((i, 3))
        } else {
            None
        }
    })
}
pub struct Frame {
    pub sps: Vec<u8>,
    pub pps: Vec<u8>,
    pub avcc: Vec<u8>,
    pub key: bool,
    pub sequence: u64,
}
impl Frame {
    pub fn send(&self, session: u64, width: u32, height: u32) -> Result<(), String> {
        let frame = MLVideoFrame {
            header: MLVideoHeader {
                width,
                height,
                sequence: self.sequence,
                keyframe: self.key as u8,
                codec: 1,
                ..Default::default()
            },
            sps: self.sps.as_ptr(),
            sps_length: self.sps.len(),
            pps: self.pps.as_ptr(),
            pps_length: self.pps.len(),
            avcc: self.avcc.as_ptr(),
            avcc_length: self.avcc.len(),
            vps: std::ptr::null(),
            vps_length: 0,
        };
        // SAFETY: frame borrows live vectors for this synchronous call.
        super::check(unsafe { ml_session_send_video(session, &frame, 1000) })
    }
}
impl Parser {
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Frame>, String> {
        if self.pending.len() + bytes.len() > LIMIT {
            return Err("encoder NAL exceeds limit".into());
        }
        self.pending.extend_from_slice(bytes);
        let mut frames = Vec::new();
        while let Some((first, prefix)) = start(&self.pending) {
            let begin = first + prefix;
            let Some((next, _)) = start(&self.pending[begin..]) else {
                break;
            };
            let end = begin + next;
            let mut nal = self.pending[begin..end].to_vec();
            while nal.last() == Some(&0) {
                nal.pop();
            }
            self.pending.drain(..end);
            if nal.is_empty() {
                continue;
            }
            match nal[0] & 31 {
                9 => {
                    if self.slices {
                        if self.sps.is_empty() || self.pps.is_empty() {
                            return Err("missing H.264 configuration".into());
                        }
                        frames.push(Frame {
                            sps: self.sps.clone(),
                            pps: self.pps.clone(),
                            avcc: std::mem::take(&mut self.unit),
                            key: self.key,
                            sequence: self.sequence,
                        });
                        self.sequence += 1;
                    }
                    self.unit.clear();
                    self.slices = false;
                    self.key = false;
                }
                7 | 8 => {
                    if nal.len() > 4096 {
                        return Err("parameter set too large".into());
                    }
                    if nal[0] & 31 == 7 {
                        self.sps = nal;
                    } else {
                        self.pps = nal;
                    }
                }
                kind @ (1 | 5 | 6 | 12) => {
                    if self.unit.len() + nal.len() + 4 > LIMIT {
                        return Err("access unit exceeds limit".into());
                    }
                    self.slices |= kind == 1 || kind == 5;
                    self.key |= kind == 5;
                    self.unit
                        .extend_from_slice(&(nal.len() as u32).to_be_bytes());
                    self.unit.extend_from_slice(&nal);
                }
                _ => return Err("unsupported encoder NAL".into()),
            }
        }
        Ok(frames)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn split_start_codes_and_configuration_are_preserved() {
        let stream = [
            0, 0, 0, 1, 9, 16, 0, 0, 1, 0x67, 66, 0, 30, 0, 0, 1, 0x68, 1, 0, 0, 1, 0x65, 9, 0, 0,
            1, 9, 16, 0, 0, 1, 0x41, 2, 0, 0, 1, 9, 16, 0, 0, 1, 9, 16,
        ];
        let mut parser = Parser::default();
        let mut frames = Vec::new();
        for chunk in stream.chunks(2) {
            frames.extend(parser.push(chunk).unwrap());
        }
        assert_eq!(frames.len(), 2);
        assert!(frames[0].key);
        assert!(!frames[1].key);
        assert_eq!(frames[0].sps, [0x67, 66, 0, 30]);
        assert_eq!(frames[0].avcc, [0, 0, 0, 2, 0x65, 9]);
        assert_eq!(frames[1].sequence, 1);
    }
    #[test]
    fn bounded_malformed_stream() {
        assert!(Parser::default().push(&vec![1; LIMIT + 1]).is_err());
        assert!(
            Parser::default()
                .push(&[0, 0, 1, 0x6b, 1, 0, 0, 1, 9])
                .is_err()
        );
    }
}

#[cfg(test)]
mod interoperability {
    use super::*;
    use std::ffi::CString;
    #[test]
    fn encoded_h264_crosses_device_paired_encrypted_session_and_reconnects() {
        // Synthetic FFmpeg test pattern, never a desktop capture. Buffers below obey the C ABI.
        unsafe {
            let directory =
                std::env::temp_dir().join(format!("mooring-linux-test-{}", std::process::id()));
            std::fs::create_dir(&directory).unwrap();
            let dir = CString::new(directory.to_str().unwrap()).unwrap();
            let host = CString::new("127.0.0.1").unwrap();
            let name = CString::new("test viewer").unwrap();
            let (mut private, mut public, mut psk) = ([0; 32], [0; 32], [0; 32]);
            assert_eq!(
                ml_session_generate_identity(
                    private.as_mut_ptr(),
                    public.as_mut_ptr(),
                    psk.as_mut_ptr()
                ),
                0
            );
            assert_eq!(ml_devices_init(dir.as_ptr(), 0), 0);
            let mut listener = 0;
            assert_eq!(
                ml_session_listen_devices(
                    host.as_ptr(),
                    0,
                    private.as_ptr(),
                    psk.as_ptr(),
                    dir.as_ptr(),
                    &mut listener
                ),
                0
            );
            let listener = super::super::Handle(listener);
            let port = ml_session_listener_port(listener.0);
            let mut secret = [0; 32];
            assert_eq!(
                ml_listener_pairing_secret(listener.0, secret.as_mut_ptr()),
                0
            );
            let mut code = std::mem::zeroed::<MLPairingCode>();
            assert_eq!(
                ml_pairing_code_for_host(
                    host.as_ptr(),
                    name.as_ptr(),
                    public.as_ptr(),
                    secret.as_ptr(),
                    2,
                    std::ptr::null(),
                    &mut code
                ),
                0
            );
            let mut device = [0; 32];
            let mut unused = [0; 32];
            let mut unused_psk = [0; 32];
            assert_eq!(
                ml_session_generate_identity(
                    device.as_mut_ptr(),
                    unused.as_mut_ptr(),
                    unused_psk.as_mut_ptr()
                ),
                0
            );
            for expected_mode in [1, 2] {
                std::thread::scope(|scope| {
                    let listener_id = listener.0;
                    let server = scope.spawn(move || {
                        let mut session = 0;
                        assert_eq!(ml_session_accept(listener_id, 5000, &mut session), 0);
                        let session = super::super::Handle(session);
                        let geometry = MLControlMessage {
                            kind: 1,
                            input_enabled: 1,
                            geometry: MLDisplayGeometry {
                                width: 64.,
                                height: 64.,
                                pixel_width: 64,
                                pixel_height: 64,
                                ..Default::default()
                            },
                            ..Default::default()
                        };
                        assert_eq!(ml_session_send_control(session.0, &geometry, 1000), 0);
                        let mut parser = Parser::default();
                        let mut frames = Vec::new();
                        for bytes in
                            include_bytes!("../tests/fixtures/test-pattern.h264").chunks(37)
                        {
                            frames.extend(parser.push(bytes).unwrap());
                        }
                        frames.extend(parser.push(&[0, 0, 1, 9, 16, 0, 0, 1, 9, 16]).unwrap());
                        assert_eq!(frames.len(), 4);
                        for frame in frames {
                            frame.send(session.0, 64, 64).unwrap();
                        }
                        let mut message = MLSessionMessage::default();
                        let mut buffer = vec![0; 12582912];
                        loop {
                            assert_eq!(
                                ml_session_receive(
                                    session.0,
                                    buffer.as_mut_ptr(),
                                    buffer.len(),
                                    &mut message,
                                    2000
                                ),
                                0
                            );
                            if message.kind == 2 {
                                assert_eq!(message.input.key_code, 0);
                                break;
                            }
                        }
                    });
                    let (mut session, mut mode) = (0, 0);
                    let mut used = [0; ML_TEXT_CAPACITY];
                    assert_eq!(
                        ml_session_connect_paired(
                            host.as_ptr(),
                            port,
                            &code,
                            device.as_ptr(),
                            name.as_ptr(),
                            4000,
                            &mut session,
                            &mut mode,
                            used.as_mut_ptr()
                        ),
                        0
                    );
                    assert_eq!(mode, expected_mode);
                    let session = super::super::Handle(session);
                    let mut message = MLSessionMessage::default();
                    let mut buffer = vec![0; 12582912];
                    let mut received = 0;
                    while received < 4 {
                        assert_eq!(
                            ml_session_receive(
                                session.0,
                                buffer.as_mut_ptr(),
                                buffer.len(),
                                &mut message,
                                2000
                            ),
                            0
                        );
                        if message.kind == 1 {
                            assert_eq!(message.video.header.width, 64);
                            assert_eq!(message.video.header.sequence, received);
                            received += 1;
                        }
                    }
                    assert_eq!(
                        ml_session_send_input(
                            session.0,
                            &MLInputEvent {
                                kind: 1,
                                key_code: 0,
                                ..Default::default()
                            },
                            1000
                        ),
                        0
                    );
                    server.join().unwrap();
                });
                let mut paired = std::mem::zeroed::<MLPairingCode>();
                assert_eq!(ml_pairing_device(&code, &mut paired), 0);
                code = paired;
            }
            drop(listener);
            std::fs::remove_dir_all(directory).unwrap();
        }
    }
}
