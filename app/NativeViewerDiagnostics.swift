import Foundation

/// Presentation of streamed session measurements. Local rates cover a rolling
/// second; host values come from arriving telemetry. Counters are session totals.
struct NativeViewerDiagnostics {
    var state = "Connecting…"
    var connected = false
    var local: NativeStats = [:]
    var host: NativeStats = [:]
    var hostAge: TimeInterval?
    var totals: [String: Double] = [:]
    var codec: String?
    var hardwareDecoder: Bool?
    var videoArea: String?
    var protocolVersion: Int?
    var peerVersion: NativeVersion?
    var audio: NativeAudioStats?
    var soundEnabled = true

    struct Section {
        let title: String
        let rows: [(name: String, value: String)]
    }
    /// Host samples older than three ticks are visibly unavailable, rather
    /// than presented as the host's current bitrate or encoder performance.
    var freshHost: NativeStats {
        guard connected, let hostAge, hostAge.isFinite, hostAge >= 0, hostAge <= 3 else { return [:] }
        return host
    }
    var hostNotice: String {
        guard connected else { return state }
        guard let hostAge else { return "Live local telemetry · waiting for host" }
        return hostAge <= 3 ? "Live telemetry stream" : "Host measurements are stale (\(Self.number(hostAge, unit: "s")) old)"
    }
    static func number(_ value: Double?, digits: Int = 0, unit: String = "") -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.*f", digits, value) + (unit.isEmpty ? "" : " " + unit)
    }
    private func pair(_ first: Double?, _ second: Double?, digits: Int = 0, unit: String) -> String {
        "\(Self.number(first, digits: digits)) / \(Self.number(second, digits: digits)) \(unit)"
    }
    var sections: [Section] {
        let host = freshHost
        let local = connected ? local : [:]
        let totals = connected ? totals : [:]
        let width = totals["capture_pixel_width"], height = totals["capture_pixel_height"]
        let pixels = width.flatMap { w in height.map { "\(Self.number(w)) × \(Self.number($0)) px" } } ?? "—"
        let elapsed = totals["session_seconds"].flatMap { seconds -> String? in
            guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return nil }
            let minutes = Int(seconds / 60)
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, Int(seconds) % 60)
        } ?? "—"
        let decode = connected ? codec.map { name in
            name + (hardwareDecoder == true ? " · hardware" : "")
        } ?? "—" : "—"
        let sound = connected ? audio : nil
        let audioFormat = sound.map { $0.packets > 0 ? "Opus · 48 kHz · stereo" + (soundEnabled ? "" : " · muted") : "Awaiting audio" } ?? "—"
        return [
            Section(title: "Session", rows: [
                ("Connection", state), ("Duration", elapsed),
                ("Transport", connected ? "Encrypted TCP · protocol \(protocolVersion.map(String.init) ?? "—")" : "—"),
                ("Local / host build", "\(NativeVersion.local.build) / \(connected ? peerVersion.map { String($0.build) } ?? "—" : "—")")
            ]),
            Section(title: "Picture & throughput", rows: [
                ("Video", decode), ("Stream size", pixels), ("Video area", connected ? videoArea ?? "—" : "—"),
                ("Received video", Self.number(local[.receivedMbps], digits: 2, unit: "Mbps")),
                ("Host bitrate target", Self.number(host[.bitrateMbps], digits: 2, unit: "Mbps")),
                ("Receive / decode", pair(local[.receivedFps], local[.decodedFps], digits: 1, unit: "fps")),
                ("Presented / cap", pair(local[.presentedFps], host[.fpsCap], digits: 1, unit: "fps")),
                ("Capture / encode", pair(host[.captureFps], host[.encodedFps], digits: 1, unit: "fps")),
                ("Host skip / drop", pair(host[.skippedFps], host[.droppedFps], digits: 1, unit: "fps"))
            ]),
            Section(title: "Timing", rows: [
                ("Screen → display", pair(local[.latencyMs], local[.latencyMsP95], unit: "ms · p50 / p95")),
                ("Clock uncertainty", Self.number(local[.clockErrorMs], digits: 1, unit: "ms")),
                ("Network round trip", Self.number(local[.rttMs], digits: 1, unit: "ms")),
                ("Host encode", Self.number(host[.encodeMs], digits: 1, unit: "ms avg")),
                ("Viewer decode", Self.number(local[.decodeMs], digits: 1, unit: "ms avg")),
                ("Decoded → display", Self.number(local[.displayWaitMs], digits: 1, unit: "ms median")),
                ("Host send queue", Self.number(host[.sendQueueKib], digits: 1, unit: "KiB peak")),
                ("Host queue wait", Self.number(host[.queueWaitMs], unit: "ms in host sample"))
            ]),
            Section(title: "Recovery & sound", rows: [
                ("Keyframe requests", Self.number(connected ? totals["keyframe_requests", default: 0] : nil)),
                ("Decode overflows", Self.number(connected ? totals["decoder_overflows", default: 0] : nil)),
                ("Audio", audioFormat),
                ("Audio buffered", Self.number(sound.map { Double($0.bufferedFrames) / 48 }, digits: 1, unit: "ms")),
                ("Audio underruns", Self.number(sound.map { Double($0.underruns) })),
                ("Audio gaps / drops", pair(sound.map { Double($0.gaps) }, sound.map { Double($0.droppedPackets) }, unit: "packets"))
            ])
        ]
    }
}
