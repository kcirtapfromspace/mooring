import Foundation
import CoreGraphics
import os

/// Session lifecycle in the macOS log (subsystem dev.maclink, category session):
/// starts, ends with MacLink's own reason text, reconnects and tuning. Never
/// addresses, names, pairing material, input or screen content.
enum NativeLog {
    static let session = Logger(subsystem: "dev.maclink", category: "session")
    static let updates = Logger(subsystem: "dev.maclink", category: "updates")
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
    /// Protocol 5: the peer's capabilities. Rust sends ours automatically.
    case hello(UInt64)
    /// Protocol 5, viewer to host: share a display of this many points at
    /// scale 1 or 2. All zero asks for the host's own display again.
    case displayRequest(width: Int, height: Int, scale: Int)
    /// Protocol 5, host to a viewer that measures latency: a pong carrying the
    /// host's clock when it received the ping, in microseconds.
    case clock(UInt64, hostUs: UInt64)
    /// Protocol 5, either way, once: the sender's MacLink version.
    case version(NativeVersion)
    /// Protocol 5, viewer to a sharing Mac that updates itself.
    case updateRequest
    /// Protocol 5, sharing Mac to viewer; for ready, the waiting update.
    case updateStatus(NativeUpdateState, ready: NativeVersion?)
    /// Protocol 5, viewer to a sharing Mac that waits for dropped viewers:
    /// this viewer is ending the session on purpose.
    case leaving

    var raw: MLControlMessage {
        var raw = MLControlMessage()
        switch self {
        case .geometry(let geometry, let enabled):
            raw.kind = UInt8(ML_CONTROL_GEOMETRY); raw.geometry = geometry.raw; raw.input_enabled = enabled ? 1 : 0
        case .inputState(let enabled): raw.kind = UInt8(ML_CONTROL_INPUT_STATE); raw.input_enabled = enabled ? 1 : 0
        case .ping(let id): raw.kind = UInt8(ML_CONTROL_PING); raw.ping_id = id
        case .pong(let id): raw.kind = UInt8(ML_CONTROL_PONG); raw.ping_id = id
        case .keyframe: raw.kind = UInt8(ML_CONTROL_KEYFRAME)
        case .hello(let capabilities): raw.kind = UInt8(ML_CONTROL_HELLO); raw.ping_id = capabilities
        case .displayRequest(let width, let height, let scale):
            raw.kind = UInt8(ML_CONTROL_DISPLAY_REQUEST)
            raw.geometry.width = Double(width); raw.geometry.height = Double(height)
            raw.geometry.pixel_width = UInt32(clamping: width * scale); raw.geometry.pixel_height = UInt32(clamping: height * scale)
        case .clock(let id, let hostUs):
            raw.kind = UInt8(ML_CONTROL_CLOCK); raw.ping_id = id
            raw.geometry.pixel_width = UInt32(truncatingIfNeeded: hostUs >> 32); raw.geometry.pixel_height = UInt32(truncatingIfNeeded: hostUs)
        case .version(let version):
            raw.kind = UInt8(ML_CONTROL_VERSION); raw.ping_id = version.release; raw.geometry.pixel_width = version.build
        case .updateRequest: raw.kind = UInt8(ML_CONTROL_UPDATE_REQUEST)
        case .updateStatus(let state, let ready):
            raw.kind = UInt8(ML_CONTROL_UPDATE_STATUS); raw.geometry.pixel_height = state.rawValue
            if state == .ready, let ready { raw.ping_id = ready.release; raw.geometry.pixel_width = ready.build }
        case .leaving: raw.kind = UInt8(ML_CONTROL_LEAVING)
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
        case ML_CONTROL_HELLO: self = .hello(raw.ping_id)
        case ML_CONTROL_DISPLAY_REQUEST:
            let width = Int(raw.geometry.width), pixels = Int(raw.geometry.pixel_width)
            self = .displayRequest(width: width, height: Int(raw.geometry.height), scale: width > 0 ? pixels / width : 0)
        case ML_CONTROL_CLOCK:
            self = .clock(raw.ping_id, hostUs: UInt64(raw.geometry.pixel_width) << 32 | UInt64(raw.geometry.pixel_height))
        case ML_CONTROL_VERSION: self = .version(NativeVersion(build: raw.geometry.pixel_width, release: raw.ping_id))
        case ML_CONTROL_UPDATE_REQUEST: self = .updateRequest
        case ML_CONTROL_UPDATE_STATUS:
            guard let state = NativeUpdateState(rawValue: raw.geometry.pixel_height) else {
                throw NativeSessionError(message: "The other Mac sent an unsupported session command.")
            }
            let ready = state == .ready ? NativeVersion(build: raw.geometry.pixel_width, release: raw.ping_id) : nil
            self = .updateStatus(state, ready: ready)
        case ML_CONTROL_LEAVING: self = .leaving
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
    static let captureMs = Self(ML_METRIC_CAPTURE_MS)
    static let sendQueueKib = Self(ML_METRIC_SEND_QUEUE_KIB)
    static let queueWaitMs = Self(ML_METRIC_QUEUE_WAIT_MS)
    static let linkMbps = Self(ML_METRIC_LINK_MBPS)
    static let latencyMs = Self(ML_METRIC_LATENCY_MS)
    static let latencyMsP95 = Self(ML_METRIC_LATENCY_MS_P95)
    static let toViewerMs = Self(ML_METRIC_TO_VIEWER_MS)
    static let displayWaitMs = Self(ML_METRIC_DISPLAY_WAIT_MS)
    static let clockErrorMs = Self(ML_METRIC_CLOCK_ERROR_MS)
}

/// Host: the send-buffer limit for starting a frame. Rust sets it from the
/// fastest round trip of the last ten seconds and the bytes sent in the last
/// one; call `update` once a second. `bytes` may be read from any queue.
final class NativeFlowLimit: @unchecked Sendable {
    static let window = 10
    private let lock = NSLock()
    private var limit = ml_flow_queue_limit(0, 0)
    private var roundTrips: [UInt32] = []
    /// Bytes sent in each recent second: the most of them sets the limit, so
    /// one quiet second doesn't shrink it before a burst.
    private var sentRates: [UInt64] = []
    private var lastSent: UInt64?
    /// Rust measures the link's rate while video waits for it.
    private var meter = MLLinkMeter()
    var bytes: UInt32 { lock.lock(); defer { lock.unlock() }; return limit }
    /// Each send-buffer reading, as frames are admitted.
    func sample(_ queue: MLSendQueue) {
        var queue = queue
        let now = UInt64(ProcessInfo.processInfo.systemUptime * 1000)
        lock.lock(); _ = ml_flow_link_sample(&meter, now, &queue); lock.unlock()
    }
    /// The link's rate since the last call, kbit/s, or 0 if it wasn't measured.
    func takeLinkKbps() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return ml_flow_link_take_kbps(&meter)
    }
    func update(_ queue: MLSendQueue) {
        lock.lock(); defer { lock.unlock() }
        if queue.round_trip_ms > 0 {
            roundTrips.append(queue.round_trip_ms)
            if roundTrips.count > Self.window { roundTrips.removeFirst(roundTrips.count - Self.window) }
        }
        let sent = lastSent.map { queue.sent_bytes >= $0 ? queue.sent_bytes - $0 : 0 } ?? 0
        lastSent = queue.sent_bytes
        sentRates.append(sent)
        if sentRates.count > Self.window { sentRates.removeFirst(sentRates.count - Self.window) }
        limit = ml_flow_queue_limit(roundTrips.min() ?? 0, sentRates.max() ?? 0)
    }
    func reset() {
        lock.lock(); roundTrips.removeAll(); sentRates.removeAll(); lastSent = nil; limit = ml_flow_queue_limit(0, 0); meter = MLLinkMeter()
        lock.unlock()
    }
}

/// What this Mac announces in protocol 5. Pointer shapes, gestures, latency,
/// versions and waiting for a dropped viewer need nothing beyond this build;
/// the rest depend on launch self-tests, and remote updates on a release
/// build with an update feed.
enum NativeCapabilities {
    static func local(hevc444: Bool, virtualDisplay: Bool, audio: Bool, updatesItself: Bool = false) -> UInt64 {
        var capabilities = UInt64(ML_CAPABILITY_CURSOR) | UInt64(ML_CAPABILITY_GESTURES) | UInt64(ML_CAPABILITY_LATENCY)
            | UInt64(ML_CAPABILITY_VERSION) | UInt64(ML_CAPABILITY_WAITS)
        if hevc444 { capabilities |= UInt64(ML_CAPABILITY_HEVC_444) }
        if virtualDisplay { capabilities |= UInt64(ML_CAPABILITY_VIRTUAL_DISPLAY) }
        if audio { capabilities |= UInt64(ML_CAPABILITY_AUDIO) }
        if updatesItself { capabilities |= UInt64(ML_CAPABILITY_REMOTE_UPDATE) }
        return capabilities
    }
}

enum NativeUpdateState: UInt32 {
    case checking = 1, upToDate, ready, failed
}

/// A MacLink version: the build number and the release, packed by Rust so
/// later releases compare greater. Release 0 is a development build.
struct NativeVersion: Equatable {
    let build: UInt32
    let release: UInt64

    /// This copy of MacLink. Only release builds carry an update feed; others
    /// report as development builds so they never claim to be newer.
    static let local: NativeVersion = {
        let info = Bundle.main.infoDictionary ?? [:]
        let build = UInt32(info["CFBundleVersion"] as? String ?? "") ?? 1
        var release: UInt64 = 0
        if info["SUFeedURL"] != nil, let text = info["MacLinkReleaseVersion"] as? String, ml_release_pack(text, &release) != ML_SESSION_OK {
            release = 0
        }
        return NativeVersion(build: max(1, build), release: release)
    }()
    init(build: UInt32, release: UInt64) { self.build = build; self.release = release }
    /// For example "0.3.0 preview 19", or "a development build".
    var name: String {
        var text = [CChar](repeating: 0, count: Int(ML_RELEASE_CAPACITY))
        guard ml_release_display(release, &text, text.count) == ML_SESSION_OK else { return "build \(build)" }
        return nativeString(text)
    }
    /// nil when either is a development build, which can't be ordered.
    func compared(to other: NativeVersion) -> ComparisonResult? {
        guard release != 0, other.release != 0 else { return nil }
        if release != other.release { return release < other.release ? .orderedAscending : .orderedDescending }
        if build != other.build { return build < other.build ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }
}

/// Viewer: the host's clock relative to this Mac's, from recent clock replies.
/// Rust picks the sample with the shortest round trip. Main thread.
final class NativeClockSync {
    static let maxSamples = 16
    private var samples: [MLClockSample] = []
    /// Host minus viewer time and its error bound, in microseconds.
    private(set) var estimate: (offsetUs: Int64, errorUs: UInt64)?

    func add(sentUs: UInt64, receivedUs: UInt64, hostUs: UInt64) {
        samples.append(MLClockSample(sent_us: sentUs, received_us: receivedUs, host_us: hostUs))
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
        var result = MLClockEstimate()
        estimate = ml_clock_estimate(samples, samples.count, &result) == ML_SESSION_OK ? (result.offset_us, result.error_us) : nil
    }
    func reset() { samples.removeAll(); estimate = nil }

    /// Milliseconds from the host's screen change to each stage here, or nil
    /// before the clocks are placed or for a value outside 0 to 2 s.
    func latency(_ timing: NativeFrameTiming) -> (total: Double, toViewer: Double, displayWait: Double)? {
        guard let estimate, timing.presentedUs > 0, timing.hostUs <= UInt64(Int64.max) else { return nil }
        let hostHere = Int64(timing.hostUs) - estimate.offsetUs
        func since(_ start: Int64, _ end: UInt64) -> Double? {
            guard end <= UInt64(Int64.max) else { return nil }
            let milliseconds = Double(Int64(end) - start) / 1000
            return (0...2000).contains(milliseconds) ? milliseconds : nil
        }
        guard let total = since(hostHere, timing.presentedUs), let toViewer = since(hostHere, timing.decodeStartUs),
              timing.presentedUs >= timing.decodedUs else { return nil }
        return (total, toViewer, Double(timing.presentedUs - timing.decodedUs) / 1000)
    }
}

/// Bounded latency samples between reports, with their percentiles.
struct NativeLatencyWindow {
    static let capacity = 1_200
    private(set) var totals: [Double] = []
    private var toViewer: [Double] = []
    private var displayWait: [Double] = []
    mutating func add(_ value: (total: Double, toViewer: Double, displayWait: Double)) {
        guard totals.count < Self.capacity else { return }
        totals.append(value.total); toViewer.append(value.toViewer); displayWait.append(value.displayWait)
    }
    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }
    /// Median and 95th percentile of the total, and the medians of the stages.
    var summary: (p50: Double, p95: Double, toViewer: Double, displayWait: Double)? {
        guard let p50 = Self.percentile(totals, 0.5), let p95 = Self.percentile(totals, 0.95),
              let toViewer = Self.percentile(toViewer, 0.5), let displayWait = Self.percentile(displayWait, 0.5) else { return nil }
        return (p50, p95, toViewer, displayWait)
    }
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
    /// 0: keyframes only when needed, Rust's ML_KEYFRAMES_ON_DEMAND.
    var keyframeSeconds: Int { raw.keyframe_seconds == UInt8(ML_KEYFRAMES_ON_DEMAND) ? 0 : Int(raw.keyframe_seconds) }
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
    /// For a value that no longer applies, so it isn't reported as current.
    func remove(_ key: String) {
        lock.lock(); values[key] = nil; lock.unlock()
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
    /// The newest pointer move not yet written. Later moves replace it until
    /// another message queues behind it, so moves never reorder with key or
    /// button edges and a slow write (a large clipboard) cannot fill the queue.
    private final class PendingMove { var event: NativeInputEvent; init(_ event: NativeInputEvent) { self.event = event } }
    private var openMove: PendingMove?
    private var peerStats = NativeStats()
    private var peerStatsTime: TimeInterval?
    private var leaving = false
    /// Host: the viewer said it was ending the session on purpose. Set on the
    /// reader thread, since a queued main-thread update is skipped once the
    /// connection closes right after.
    var viewerLeft: Bool { lock.lock(); defer { lock.unlock() }; return leaving }
    func noteViewerLeaving() { lock.lock(); leaving = true; lock.unlock() }
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
        var move: NativeInputEvent?
        if case .input(let event) = message, event.kind == .pointerMove { move = event }
        lock.lock()
        if let move, let open = openMove {
            open.event = move; lock.unlock(); completion?()
            return
        }
        guard token.isActive, pending < 64 else {
            lock.unlock(); completion?()
            if token.isActive { fail("The connection could not keep up. Reconnect to resume safely.") }
            return
        }
        pending += 1
        let slot = move.map(PendingMove.init)
        openMove = slot
        lock.unlock()
        writer.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock(); completion?() }
            var outgoing = message
            if let slot {
                lock.lock(); if openMove === slot { openMove = nil }; outgoing = .input(slot.event); lock.unlock()
            }
            guard token.isActive else { return }
            let began = ProcessInfo.processInfo.systemUptime
            do {
                try transport.send(outgoing)
                if case .video(let packet) = message {
                    let milliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1000
                    measurements.add("video_send_ms_total", milliseconds); measurements.recordMax("video_send_ms", milliseconds)
                    measurements.set("last_video_send_ms", milliseconds)
                    measurements.add("sent_video_frames"); measurements.add("sent_video_bytes", Double(packet.wireSize))
                }
            } catch {
                // Rust refuses an invalid clipboard before writing; the session is unaffected.
                if case .clipboard = outgoing, (error as? NativeSessionError)?.status == Int32(ML_SESSION_INVALID) {
                    NativeLog.session.notice("clipboard not sent: Rust rejected its contents")
                    return
                }
                fail(error.localizedDescription)
            }
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
    /// Writes `message` after anything already queued, then closes. The write
    /// is bounded by the send timeout; if it fails, the channel just closes.
    func close(after message: NativeSessionMessage) { send(message) { [self] in close() } }
    deinit { transport.close() }
}
