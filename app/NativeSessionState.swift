import Foundation
import CoreGraphics

final class NativeRunToken: @unchecked Sendable {
    private let lock = NSLock()
    private var live = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return live }
    @discardableResult func cancel() -> Bool { lock.lock(); defer { lock.unlock() }; let old = live; live = false; return old }
}

/// Session control messages. Rust validates fields and direction on send and
/// receive; this enum only maps them to and from the C ABI.
enum NativeControlMessage: Equatable {
    case geometry(NativeDisplayGeometry, inputEnabled: Bool)
    case inputState(enabled: Bool)
    case ping(UInt64)
    case pong(UInt64)
    case keyframe

    var raw: MLControlMessage {
        var raw = MLControlMessage()
        switch self {
        case .geometry(let geometry, let enabled):
            raw.kind = UInt8(ML_CONTROL_GEOMETRY); raw.geometry = geometry.raw; raw.input_enabled = enabled ? 1 : 0
        case .inputState(let enabled): raw.kind = UInt8(ML_CONTROL_INPUT_STATE); raw.input_enabled = enabled ? 1 : 0
        case .ping(let id): raw.kind = UInt8(ML_CONTROL_PING); raw.ping_id = id
        case .pong(let id): raw.kind = UInt8(ML_CONTROL_PONG); raw.ping_id = id
        case .keyframe: raw.kind = UInt8(ML_CONTROL_KEYFRAME)
        }
        return raw
    }
    /// For messages Rust has already validated.
    init(validated raw: MLControlMessage) throws {
        switch Int(raw.kind) {
        case ML_CONTROL_GEOMETRY: self = .geometry(NativeDisplayGeometry(raw.geometry), inputEnabled: raw.input_enabled == 1)
        case ML_CONTROL_INPUT_STATE: self = .inputState(enabled: raw.input_enabled == 1)
        case ML_CONTROL_PING: self = .ping(raw.ping_id)
        case ML_CONTROL_PONG: self = .pong(raw.ping_id)
        case ML_CONTROL_KEYFRAME: self = .keyframe
        default: throw NativeSessionError(message: "The other Mac sent an unsupported session command.")
        }
    }
}

/// Bounded diagnostics contain measurements only: no address, identity, input,
/// screen contents, credentials or cross-machine one-way timestamp subtraction.
final class NativeSessionMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var values: [String: Double] = [:]
    func set(_ key: String, _ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        lock.lock(); values[key] = value; lock.unlock()
    }
    func add(_ key: String, _ amount: Double = 1) {
        guard amount.isFinite, amount >= 0 else { return }
        lock.lock()
        let next = values[key, default: 0] + amount
        if next.isFinite { values[key] = next }
        lock.unlock()
    }
    func snapshot() -> [String: Double] {
        lock.lock(); var result = values; lock.unlock()
        result["session_seconds"] = ProcessInfo.processInfo.systemUptime - started
        return result
    }
    func report() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": 1, "measurements": snapshot(),
            "notes": ["Prototype measurements; not click-to-photon latency.",
                      "TCP streaming; no claim of Apple performance parity."]], options: [.prettyPrinted, .sortedKeys])
    }
}

/// The application never accumulates an unbounded queue of input or controls.
/// If ordered key/button edges cannot be retained, disconnect to release input.
final class NativeSessionChannel: @unchecked Sendable {
    let transport: NativeTransport
    let token = NativeRunToken()
    let measurements = NativeSessionMeasurements()
    private let writer = DispatchQueue(label: "dev.maclink.native.writer", qos: .userInteractive)
    private let lock = NSLock()
    private var pending = 0
    private var pendingMain = 0
    var onFailure: ((String) -> Void)?
    init(_ transport: NativeTransport) { self.transport = transport }
    func send(_ message: NativeSessionMessage, completion: (() -> Void)? = nil) {
        lock.lock()
        guard token.isActive, pending < 64 else {
            lock.unlock(); completion?()
            if token.isActive { fail("The connection could not keep up. Reconnect to resume safely.") }
            return
        }
        pending += 1; lock.unlock()
        writer.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock(); completion?() }
            guard token.isActive else { return }
            let began = ProcessInfo.processInfo.systemUptime
            do {
                try transport.send(message)
                if case .video(let packet) = message {
                    measurements.set("last_video_send_ms", (ProcessInfo.processInfo.systemUptime - began) * 1000)
                    measurements.add("sent_video_frames"); measurements.add("sent_video_bytes", Double(packet.wireSize))
                }
            } catch { fail(error.localizedDescription) }
        }
    }
    func deliverControl(_ body: @escaping () -> Void) {
        lock.lock()
        guard token.isActive, pendingMain < 16 else {
            lock.unlock()
            if token.isActive { fail("The viewer could not keep up with session updates.") }
            return
        }
        pendingMain += 1; lock.unlock()
        DispatchQueue.main.async { [self] in
            defer { lock.lock(); pendingMain -= 1; lock.unlock() }
            guard token.isActive else { return }
            body()
        }
    }
    func control(_ message: NativeControlMessage) { send(.control(message)) }
    func fail(_ message: String) {
        guard token.cancel() else { return }
        transport.close()
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
    }
    func close() { token.cancel(); transport.close() }
    deinit { transport.close() }
}
