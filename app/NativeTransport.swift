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
    static func listen(identity: NativeHostIdentity, bindAddress: String = "0.0.0.0", port: UInt16 = 45900) throws -> NativeTransport {
        try identity.validate()
        var handle: UInt64 = 0
        let status = identity.privateKey.withUnsafeBytes { privateBytes in
            identity.secret.withUnsafeBytes { secretBytes in
                ml_session_listen(bindAddress, port,
                                  privateBytes.bindMemory(to: UInt8.self).baseAddress!,
                                  secretBytes.bindMemory(to: UInt8.self).baseAddress!, &handle)
            }
        }
        try check(status)
        return NativeTransport(handle, receivesVideo: false)
    }
    static func connect(address: String, code: NativePairingCode, port: UInt16 = 45900) throws -> NativeTransport {
        var handle: UInt64 = 0
        var raw = code.raw
        let status = withUnsafeBytes(of: &raw.public_key) { publicBytes in
            withUnsafeBytes(of: &raw.secret) { secretBytes in
                ml_session_connect(address, port,
                                   publicBytes.bindMemory(to: UInt8.self).baseAddress!,
                                   secretBytes.bindMemory(to: UInt8.self).baseAddress!, 5_000, &handle)
            }
        }
        if status == ML_SESSION_INVALID { throw NativeSessionError(message: "Enter a hostname or IP address, without a port or URL.") }
        try check(status)
        return NativeTransport(handle, receivesVideo: true)
    }
    var listeningPort: UInt16 { ml_session_listener_port(id) }
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
        }
        try Self.check(status)
    }
    /// Exactly one receiver per connection; returned packets own their bytes.
    func receive() throws -> NativeSessionMessage? {
        // Allocated on first receive, and only by viewers. Keep this a stored
        // property: accessor-backed inout access would copy it per call.
        if receivesVideo && videoBuffer.isEmpty { videoBuffer = [UInt8](repeating: 0, count: Int(ML_SESSION_MAX_VIDEO)) }
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
            return .video(NativeVideoPacket(header: packet.header, sps: slice(packet.sps_offset, packet.sps_length),
                                            pps: slice(packet.pps_offset, packet.pps_length),
                                            avcc: slice(packet.avcc_offset, packet.avcc_length)))
        case ML_SESSION_INPUT: return .input(try NativeInputEvent(message.input))
        case ML_SESSION_CONTROL: return .control(try NativeControlMessage(validated: message.control))
        case ML_SESSION_TELEMETRY: return .telemetry(try NativeTelemetry(validated: message.telemetry))
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
