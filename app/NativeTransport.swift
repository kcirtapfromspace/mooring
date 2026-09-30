import Foundation

/// Reads a NUL-terminated C character array imported as a tuple, or a [CChar].
func nativeString<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
}
func nativeString(_ value: [CChar]) -> String {
    value.withUnsafeBytes { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
}

/// One typed session message. Rust validates every field, direction and rate.
enum NativeSessionMessage {
    case video(NativeVideoPacket)
    case input(NativeInputEvent)
    case control(NativeControlMessage)
    case telemetry(NativeTelemetry)
    case clipboard(NativeClipboardContent)
    case cursor(NativeCursorImage)
    case audio(NativeAudioPacket)
}

/// The sharing Mac's pointer: size and hotspot in points, and a PNG that may
/// carry Retina pixels. Rust validates both on send and receive.
struct NativeCursorImage: Equatable {
    let width: Int
    let height: Int
    let hotspotX: Int
    let hotspotY: Int
    let png: Data
}

/// Blocking Rust I/O is called only from dedicated network queues. Registry IDs
/// in Rust keep a concurrent close safe and unblock readers without freeing them.
/// A listener-accepted transport is the sharing host; a connected one is the viewer.
final class NativeTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: UInt64
    private let receivesVideo: Bool
    private var videoBuffer: [UInt8] = []
    private init(_ handle: UInt64, receivesVideo: Bool) { self.handle = handle; self.receivesVideo = receivesVideo }
    private var id: UInt64 { lock.lock(); defer { lock.unlock() }; return handle }
    static func check(_ status: Int32) throws {
        guard status == 0 else {
            throw NativeSessionError(message: String(cString: ml_session_error_string(status)), status: status)
        }
    }
    /// Listens for Macs approved in `devices`, and for the old code while that
    /// store still accepts it.
    static func listen(identity: NativeHostIdentity, devices: NativeDeviceStore,
                       bindAddress: String = "0.0.0.0", port: UInt16 = 45900) throws -> NativeTransport {
        try identity.validate()
        var handle: UInt64 = 0
        let status = identity.privateKey.withUnsafeBytes { privateBytes in
            identity.secret.withUnsafeBytes { secretBytes in
                ml_session_listen_devices(bindAddress, port,
                                          privateBytes.bindMemory(to: UInt8.self).baseAddress!,
                                          secretBytes.bindMemory(to: UInt8.self).baseAddress!, devices.directory, &handle)
            }
        }
        try check(status)
        return NativeTransport(handle, receivesVideo: false)
    }
    /// Listener only: a new one-time code's secret, replacing any unused one.
    func newPairingSecret() throws -> Data {
        var secret = [UInt8](repeating: 0, count: 32)
        defer { for index in secret.indices { secret[index] = 0 } }
        try Self.check(ml_listener_pairing_secret(id, &secret))
        return Data(secret)
    }
    /// How a connection proved this Mac.
    enum Mode: UInt8 {
        /// The old code, to a sharing Mac from before per-device keys.
        case legacy = 0
        /// A one-time code approved this Mac's key.
        case pair = 1
        /// An approved key.
        case device = 2
        /// The old code approved this Mac's key, once.
        case migrate = 3
        /// The sharing Mac approved this Mac's key; save the device pairing.
        var approvedKey: Bool { self == .pair || self == .migrate }
    }
    /// Connects with a pasted code or saved pairing, proving this Mac's key.
    static func connect(address: String, code: NativePairingCode, deviceKey: NativeDeviceKey,
                        deviceName: String = NativeDeviceKey.computerName, port: UInt16 = 45900) throws -> (NativeTransport, Mode) {
        guard deviceKey.privateKey.count == 32 else { throw NativeSessionError(message: "This Mac's device key is invalid. Pair the Macs again.") }
        var handle: UInt64 = 0
        var mode: UInt8 = 0
        var raw = code.raw
        let status = deviceKey.privateKey.withUnsafeBytes { keyBytes in
            ml_session_connect_paired(address, port, &raw, keyBytes.bindMemory(to: UInt8.self).baseAddress!, deviceName,
                                      5_000, &handle, &mode)
        }
        if status == ML_SESSION_INVALID { throw NativeSessionError(message: "Enter a hostname or IP address, without a port or URL.") }
        try check(status)
        guard let used = Mode(rawValue: mode) else { _ = ml_session_close(handle); throw NativeSessionError(message: "Internal error") }
        return (NativeTransport(handle, receivesVideo: true), used)
    }
    var listeningPort: UInt16 { ml_session_listener_port(id) }
    /// 4 or 5; capabilities are exchanged only in protocol 5.
    var protocolVersion: Int { Int(max(0, ml_session_protocol_version(id))) }
    /// The kernel's send buffer and round trip for this connection, or nil
    /// once it has closed.
    func sendQueue() -> MLSendQueue? {
        var queue = MLSendQueue()
        return ml_session_send_queue(id, &queue) == ML_SESSION_OK ? queue : nil
    }
    /// Host: the approved Mac on the other end, "" for one using the old
    /// code, or nil once closed.
    var peerDevice: String? {
        var out = [CChar](repeating: 0, count: Int(ML_PEER_ID_CAPACITY))
        return ml_session_peer_device(id, &out) == ML_SESSION_OK ? nativeString(out) : nil
    }
    /// What the peer announced; zero until its Hello arrives.
    var peerCapabilities: UInt64 { var value: UInt64 = 0; _ = ml_session_peer_capabilities(id, &value); return value }
    func accept() throws -> NativeTransport? {
        var session: UInt64 = 0
        let result = ml_session_accept(id, 1_000, &session)
        if result == ML_SESSION_TIMEOUT { return nil }
        try Self.check(result)
        return NativeTransport(session, receivesVideo: false)
    }
    /// A write that cannot finish within the timeout ends the session. Brief
    /// Wi-Fi stalls are longer than 3 s; the 10 s idle limit still ends a dead link.
    func send(_ message: NativeSessionMessage, timeout: UInt32 = 8_000) throws {
        let session = id
        let status: Int32
        switch message {
        case .video(let packet): status = packet.withFrame { ml_session_send_video(session, $0, timeout) }
        case .input(let event): var raw = event.raw; status = ml_session_send_input(session, &raw, timeout)
        case .control(let control): var raw = control.raw; status = ml_session_send_control(session, &raw, timeout)
        case .telemetry(let telemetry): var raw = telemetry.raw; status = ml_session_send_telemetry(session, &raw, timeout)
        case .clipboard(let content):
            status = content.withItems { ml_session_send_clipboard(session, $0.baseAddress, $0.count, timeout) }
        case .cursor(let cursor):
            status = cursor.png.withUnsafeBytes {
                ml_session_send_cursor(session, UInt16(clamping: cursor.width), UInt16(clamping: cursor.height),
                                       UInt16(clamping: cursor.hotspotX), UInt16(clamping: cursor.hotspotY),
                                       $0.bindMemory(to: UInt8.self).baseAddress, $0.count, timeout)
            }
        case .audio(let packet):
            status = packet.payload.withUnsafeBytes {
                ml_session_send_audio(session, packet.sequence, packet.frames, packet.channels,
                                      $0.bindMemory(to: UInt8.self).baseAddress, $0.count, timeout)
            }
        }
        try Self.check(status)
    }
    /// Exactly one receiver per connection; returned packets own their bytes.
    func receive() throws -> NativeSessionMessage? {
        // Allocated on first receive: viewers receive video and clipboards, hosts
        // clipboards only. Keep this a stored property: accessor-backed inout
        // access would copy it per call.
        if videoBuffer.isEmpty {
            videoBuffer = [UInt8](repeating: 0, count: Int(receivesVideo ? ML_SESSION_MAX_VIDEO : ML_CLIPBOARD_MAX_MESSAGE))
        }
        let session = id
        var message = MLSessionMessage()
        let result = videoBuffer.withUnsafeMutableBufferPointer { buffer in
            ml_session_receive(session, buffer.baseAddress, buffer.count, &message, 1_000)
        }
        if result == ML_SESSION_TIMEOUT { return nil }
        try Self.check(result)
        switch Int(message.kind) {
        case ML_SESSION_VIDEO:
            let packet = message.video
            func slice(_ offset: Int, _ length: Int) -> Data { Data(videoBuffer[offset..<(offset + length)]) }
            return .video(NativeVideoPacket(header: packet.header, vps: slice(packet.vps_offset, packet.vps_length),
                                            sps: slice(packet.sps_offset, packet.sps_length),
                                            pps: slice(packet.pps_offset, packet.pps_length),
                                            avcc: slice(packet.avcc_offset, packet.avcc_length)))
        case ML_SESSION_INPUT: return .input(try NativeInputEvent(message.input))
        case ML_SESSION_CONTROL: return .control(try NativeControlMessage(validated: message.control))
        case ML_SESSION_TELEMETRY: return .telemetry(try NativeTelemetry(validated: message.telemetry))
        case ML_SESSION_CURSOR:
            let cursor = message.cursor
            let png = Data(videoBuffer[cursor.png_offset..<(cursor.png_offset + cursor.png_length)])
            return .cursor(NativeCursorImage(width: Int(cursor.width), height: Int(cursor.height),
                                             hotspotX: Int(cursor.hotspot_x), hotspotY: Int(cursor.hotspot_y), png: png))
        case ML_SESSION_AUDIO:
            let audio = message.audio
            let payload = Data(videoBuffer[audio.payload_offset..<(audio.payload_offset + audio.payload_length)])
            return .audio(NativeAudioPacket(sequence: audio.sequence, frames: audio.frames, channels: audio.channels, payload: payload))
        case ML_SESSION_CLIPBOARD:
            let clipboard = message.clipboard
            let ranges = withUnsafeBytes(of: clipboard.items) { Array($0.bindMemory(to: MLClipboardRange.self).prefix(Int(clipboard.count))) }
            var content = NativeClipboardContent()
            videoBuffer.withUnsafeMutableBytes { buffer in
                for range in ranges {
                    let bytes = UnsafeMutableRawBufferPointer(rebasing: buffer[range.offset..<(range.offset + range.length)])
                    let data = Data(bytes)
                    // Clipboard contents do not linger in the reused receive buffer.
                    bytes.initializeMemory(as: UInt8.self, repeating: 0)
                    switch Int(range.kind) {
                    case ML_CLIPBOARD_TEXT: content.text = String(decoding: data, as: UTF8.self) // UTF-8 checked in Rust
                    case ML_CLIPBOARD_RTF: content.rtf = data
                    default: content.png = data
                    }
                }
            }
            return .clipboard(content)
        default:
            close(); throw NativeSessionError(message: "The peer sent an unsupported message.")
        }
    }
    func close() {
        lock.lock(); let previous = handle; handle = 0; lock.unlock()
        if previous != 0 { _ = ml_session_close(previous) }
    }
    deinit { close() }
}
