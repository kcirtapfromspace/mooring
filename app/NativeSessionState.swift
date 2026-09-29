import Foundation
import CoreGraphics
import os

/// Session lifecycle in the macOS log (subsystem dev.maclink, category session):
/// starts, ends with MacLink's own reason text, reconnects and tuning. Never
/// addresses, names, pairing material, input or screen content.
enum NativeLog {
    static let session = Logger(subsystem: "dev.maclink", category: "session")
}

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

/// Measurement IDs shared with Rust (ML_METRIC_*); Rust names them in local JSON.
struct NativeMetric: Hashable {
    let id: UInt8
    private init(_ id: Int) { self.id = UInt8(id) }
    /// For IDs Rust has already validated.
    fileprivate init(validated id: UInt8) { self.id = id }
    static let captureFps = Self(ML_METRIC_CAPTURE_FPS)
    static let encodedFps = Self(ML_METRIC_ENCODED_FPS)
    static let skippedFps = Self(ML_METRIC_SKIPPED_FPS)
    static let droppedFps = Self(ML_METRIC_DROPPED_FPS)
    static let failedFrames = Self(ML_METRIC_FAILED_FRAMES)
    static let keyframes = Self(ML_METRIC_KEYFRAMES)
    static let encodeMs = Self(ML_METRIC_ENCODE_MS)
    static let encodeMsMax = Self(ML_METRIC_ENCODE_MS_MAX)
    static let sendMs = Self(ML_METRIC_SEND_MS)
    static let sendMsMax = Self(ML_METRIC_SEND_MS_MAX)
    static let sentMbps = Self(ML_METRIC_SENT_MBPS)
    static let frameKib = Self(ML_METRIC_FRAME_KIB)
    static let inFlight = Self(ML_METRIC_IN_FLIGHT)
    static let bitrateMbps = Self(ML_METRIC_BITRATE_MBPS)
    static let pixelWidth = Self(ML_METRIC_PIXEL_WIDTH)
    static let pixelHeight = Self(ML_METRIC_PIXEL_HEIGHT)
    static let fpsCap = Self(ML_METRIC_FPS_CAP)
    static let receivedFps = Self(ML_METRIC_RECEIVED_FPS)
    static let receivedMbps = Self(ML_METRIC_RECEIVED_MBPS)
    static let decodeMs = Self(ML_METRIC_DECODE_MS)
    static let decodeMsMax = Self(ML_METRIC_DECODE_MS_MAX)
    static let decodedFps = Self(ML_METRIC_DECODED_FPS)
    static let presentedFps = Self(ML_METRIC_PRESENTED_FPS)
    static let rttMs = Self(ML_METRIC_RTT_MS)
    static let keyframeRequests = Self(ML_METRIC_KEYFRAME_REQUESTS)
    static let decoderOverflows = Self(ML_METRIC_DECODER_OVERFLOWS)
}
typealias NativeStats = [NativeMetric: Double]

/// Stream settings the sharing Mac applies live. Defaults, bounds and merging
/// are Rust's; zero fields in an update mean "unchanged".
struct NativeTuning: Equatable {
    let raw: MLTuning
    static let defaults: NativeTuning = { var raw = MLTuning(); _ = ml_tuning_defaults(&raw); return NativeTuning(raw: raw) }()
    /// nil when either value is outside Rust's bounds.
    func merged(_ update: NativeTuning) -> NativeTuning? {
        var current = raw, change = update.raw, result = MLTuning()
        guard ml_tuning_merge(&current, &change, &result) == ML_SESSION_OK else { return nil }
        return NativeTuning(raw: result)
    }
    var bitrate: Int { Int(raw.bitrate_kbps) * 1000 }
    var maxWidth: Int { Int(raw.max_width) }
    var fps: Int { Int(raw.fps) }
    var inFlight: Int { Int(raw.in_flight) }
    var keyframeSeconds: Int { Int(raw.keyframe_seconds) }
    static func == (left: Self, right: Self) -> Bool {
        left.bitrate == right.bitrate && left.maxWidth == right.maxWidth && left.fps == right.fps
            && left.inFlight == right.inFlight && left.keyframeSeconds == right.keyframeSeconds
    }
}

private func metricsTuple(_ stats: NativeStats, into tuple: inout (MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric,
    MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric,
    MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric, MLMetric)) -> UInt8 {
    // Values Rust would reject are left out rather than failing the report.
    let entries = stats.filter { $0.value.isFinite && $0.value >= 0 && $0.value <= 1e9 }.prefix(Int(ML_TELEMETRY_MAX_METRICS))
    withUnsafeMutableBytes(of: &tuple) { bytes in
        let slots = bytes.bindMemory(to: MLMetric.self)
        for (index, entry) in entries.enumerated() {
            var metric = MLMetric(); metric.metric = entry.key.id; metric.value = entry.value
            slots[index] = metric
        }
    }
    return UInt8(entries.count)
}
private func statsFrom<T>(_ tuple: T, count: UInt8) -> NativeStats {
    withUnsafeBytes(of: tuple) { bytes in
        var stats = NativeStats()
        for metric in bytes.bindMemory(to: MLMetric.self).prefix(Int(count)) {
            stats[NativeMetric(validated: metric.metric)] = metric.value
        }
        return stats
    }
}

/// Telemetry between the two Macs: stats both ways, tuning viewer to host.
enum NativeTelemetry {
    case stats(NativeStats)
    case tuning(NativeTuning)

    var raw: MLTelemetryMessage {
        var raw = MLTelemetryMessage()
        switch self {
        case .stats(let stats): raw.kind = UInt8(ML_TELEMETRY_STATS); raw.count = metricsTuple(stats, into: &raw.metrics)
        case .tuning(let tuning): raw.kind = UInt8(ML_TELEMETRY_TUNING); raw.tuning = tuning.raw
        }
        return raw
    }
    /// For messages Rust has already validated.
    init(validated raw: MLTelemetryMessage) throws {
        switch Int(raw.kind) {
        case ML_TELEMETRY_STATS: self = .stats(statsFrom(raw.metrics, count: raw.count))
        case ML_TELEMETRY_TUNING: self = .tuning(NativeTuning(raw: raw.tuning))
        default: throw NativeSessionError(message: "The other Mac sent unsupported telemetry.")
        }
    }
}

/// The app's owner-only local telemetry socket (Rust). No network port.
enum NativeTelemetryServer {
    @discardableResult static func start() -> Int32 { ml_telemetry_start(nil) }
    static func stop() { _ = ml_telemetry_stop() }
    static func takeTuning() -> NativeTuning? {
        var raw = MLTuning()
        return ml_telemetry_take_tuning(&raw) == 1 ? NativeTuning(raw: raw) : nil
    }
    static func publish(role: Int, seconds: Double, local: NativeStats, peer: NativeStats, peerAge: Double?, tuning: NativeTuning,
                        lastEnd: (reason: String, age: Double)? = nil) {
        var snapshot = MLTelemetrySnapshot()
        if let lastEnd {
            // Bounded, printable UTF-8 on a character boundary; Rust rejects anything else.
            var reason = String(lastEnd.reason.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            while reason.utf8.count > Int(ML_REASON_CAPACITY) - 1 { reason.removeLast() }
            withUnsafeMutableBytes(of: &snapshot.last_end) { bytes in
                for (index, byte) in reason.utf8.enumerated() { bytes[index] = byte }
            }
            snapshot.last_end_age_seconds = max(0, lastEnd.age)
        }
        snapshot.role = UInt8(role); snapshot.session_seconds = max(0, seconds)
        snapshot.peer_age_seconds = peerAge.map { max(0, $0) } ?? -1
        snapshot.tuning = tuning.raw
        snapshot.local_count = metricsTuple(local, into: &snapshot.local)
        snapshot.peer_count = metricsTuple(peer, into: &snapshot.peer)
        _ = ml_telemetry_publish(&snapshot)
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
    private var maxima: [String: Double] = [:]
    private var intervalBaseline: [String: Double] = [:]
    private var intervalStart = ProcessInfo.processInfo.systemUptime
    /// The largest value seen for `key` since the previous interval.
    func recordMax(_ key: String, _ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        lock.lock(); maxima[key] = max(maxima[key] ?? 0, value); lock.unlock()
    }
    /// Counter changes and maxima since the previous call, for live telemetry.
    func nextInterval() -> NativeInterval {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let current = values, previous = intervalBaseline, peaks = maxima
        let seconds = now - intervalStart
        intervalBaseline = current; maxima = [:]; intervalStart = now
        lock.unlock()
        return NativeInterval(seconds: seconds, values: current, previous: previous, maxima: peaks)
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

struct NativeInterval {
    let seconds: Double
    let values: [String: Double]
    let previous: [String: Double]
    let maxima: [String: Double]
    func delta(_ key: String) -> Double { max(0, (values[key] ?? 0) - (previous[key] ?? 0)) }
    func rate(_ key: String) -> Double { seconds > 0.2 ? delta(key) / seconds : 0 }
    /// Average of a running total over the frames counted in `count`.
    func average(_ total: String, per count: String) -> Double? {
        let frames = delta(count)
        return frames > 0 ? delta(total) / frames : nil
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
    private var peerStats = NativeStats()
    private var peerStatsTime: TimeInterval?
    var onFailure: ((String) -> Void)?
    func storePeerStats(_ stats: NativeStats) {
        lock.lock(); peerStats = stats; peerStatsTime = ProcessInfo.processInfo.systemUptime; lock.unlock()
    }
    /// The peer's latest stats and their age in seconds, if any have arrived.
    func latestPeerStats() -> (NativeStats, Double?) {
        lock.lock(); defer { lock.unlock() }
        return (peerStats, peerStatsTime.map { ProcessInfo.processInfo.systemUptime - $0 })
    }
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
                    let milliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1000
                    measurements.add("video_send_ms_total", milliseconds); measurements.recordMax("video_send_ms", milliseconds)
                    measurements.set("last_video_send_ms", milliseconds)
                    measurements.add("sent_video_frames"); measurements.add("sent_video_bytes", Double(packet.wireSize))
                }
            } catch { fail(error.localizedDescription) }
        }
    }
    func deliverControl(_ body: @escaping () -> Void) {
        lock.lock()
        guard token.isActive, pendingMain < 16 else {
            lock.unlock()
            if token.isActive { fail("Session updates arrived faster than this Mac could apply them.") }
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
