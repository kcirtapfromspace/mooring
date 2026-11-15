import AppKit
import IOKit.pwr_mgt
import ApplicationServices
import SystemConfiguration
import CoreVideo
import CryptoKit

// Application workflow implementation. Invariants and wire validation live in Rust.
extension NativeSessionCoordinator {
    func pollClipboard() {
        guard sharesClipboard, isConnected || hostChannel?.token.isActive == true else { return }
        clipboard.poll()
    }
    /// A new scope captures these recipients. A delayed copy can never select
    /// a replacement channel or survive disconnect/disable/re-enable.
    func refreshClipboardScope(includeCurrent: Bool) {
        clipboard.stop()
        guard sharesClipboard, !capabilityGate.isStopped, isConnected || hostChannel?.token.isActive == true else { return }
        clipboard.onSend = { [weak self, weak viewer = viewerChannel, weak host = hostChannel] content, scope in
            self?.sendClipboard(content, to: [viewer, host].compactMap { $0 }, within: scope)
        }
        clipboard.start(includeCurrent: includeCurrent)
    }
    func sendClipboard(_ content: NativeClipboardContent, to recipients: [NativeSessionChannel], within scope: NativeRunToken) {
        guard sharesClipboard, scope.isActive else { return }
        var sent = false
        for channel in recipients where channel.token.isActive {
            channel.send(.clipboard(content), whileActive: scope)
            channel.measurements.add("clipboard_sent"); channel.measurements.add("clipboard_sent_bytes", Double(content.byteCount))
            sent = true
        }
        if sent { NativeLog.session.notice("clipboard sent: \(content.summary, privacy: .public)") }
    }
    func applyClipboard(_ content: NativeClipboardContent, from channel: NativeSessionChannel, within scope: NativeRunToken) {
        guard sharesClipboard, scope.isActive else { return }
        clipboard.apply(content, from: channel.token, within: scope)
        channel.measurements.add("clipboard_received"); channel.measurements.add("clipboard_received_bytes", Double(content.byteCount))
        NativeLog.session.notice("clipboard received: \(content.summary, privacy: .public)")
    }

    /// Once a second: resume automatic sharing, exchange stats with the
    /// connected Mac, apply or forward local tuning commands, and publish a
    /// snapshot on the local socket.
    func telemetryTick() {
        resumeSharingIfAutomatic()
        resumeViewerAfterWake()
        if let tuning = NativeTelemetryServer.takeTuning() {
            if let channel = viewerChannel, channel.token.isActive, hostChannel == nil {
                channel.send(.telemetry(.tuning(tuning))) // the sharing Mac applies it
            } else {
                applyTuning(tuning) // this Mac shares, or keeps it for its next session
            }
        }
        let ended = lastEnd.map { (reason: $0.reason, age: uptime - $0.at) }
        var published = false
        for (channel, role, stats) in [(viewerChannel, Int(ML_ROLE_VIEWER), viewerStats), (hostChannel, Int(ML_ROLE_HOST), hostStats)] {
            guard let channel, channel.token.isActive else { continue }
            if role == Int(ML_ROLE_VIEWER), let decoder { channel.measurements.set("decoder_overflows", Double(decoder.overflows)) }
            if role == Int(ML_ROLE_HOST) {
                let totals = retiredEncoderCounters.adding(capture?.encoderMetrics)
                channel.measurements.set("skipped_capture_frames", Double(totals.skipped))
                channel.measurements.set("encoder_dropped_frames", Double(totals.dropped))
                channel.measurements.set("encoder_failed_frames", Double(totals.failed))
                channel.measurements.set("queue_wait_ms", totals.queueWaitMs)
            }
            let interval = channel.measurements.nextInterval()
            if role == Int(ML_ROLE_HOST) { pace(interval) }
            let local = stats(interval)
            channel.send(.telemetry(.stats(local)))
            guard !published else { continue }
            let (peer, age) = channel.latestPeerStats()
            NativeTelemetryServer.publish(role: role, seconds: channel.measurements.snapshot()["session_seconds"] ?? 0,
                                          local: local, peer: peer, peerAge: age, tuning: hostTuning, lastEnd: ended)
            published = true
        }
        if !published {
            NativeTelemetryServer.publish(role: Int(ML_ROLE_IDLE), seconds: 0, local: [:], peer: [:], peerAge: nil,
                                          tuning: hostTuning, lastEnd: ended)
        }
    }
    /// The effective bitrate: the tuned one, or less while pacing has lowered it.
    var currentBitrate: Int {
        flowKbps > 0 ? min(hostTuning.bitrate, Int(flowKbps) * 1000) : hostTuning.bitrate
    }
    /// Host, once a second: Rust lowers the bitrate when frames keep waiting
    /// for the send buffer and raises it again after clear seconds.
    func pace(_ interval: NativeInterval) {
        guard let capture, let channel = hostChannel else { return }
        if let queue = channel.transport.sendQueue() { flowLimit.update(queue) }
        var kbps: UInt32 = 0
        let waited = UInt32(min(interval.delta("queue_wait_ms"), Double(UInt32.max)))
        let queued = UInt32(min(interval.maxima["send_queue_bytes"] ?? 0, Double(UInt32.max)))
        // An on-demand keyframe's drain, this second or spilling from the last,
        // isn't a slow connection. Periodic keyframes, when tuned, still count.
        let keyframe = interval.delta("encoded_keyframes") > 0
        let afterKeyframe = hostTuning.keyframeSeconds == 0 && (keyframe || keyframeLastSecond)
        keyframeLastSecond = keyframe
        // What the link carried while video waited for it: where a cut goes.
        // What was sent keeps a stall from passing for a slow link.
        let link = flowLimit.takeLinkKbps()
        lastLinkKbps = link
        let sent = UInt32(min(max(interval.rate("sent_video_bytes") * 8 / 1000, 0), Double(UInt32.max)))
        guard ml_flow_next_bitrate(flowKbps, UInt32(hostTuning.bitrate / 1000), waited, afterKeyframe ? 1 : 0, link, sent,
                                   &flowState, &kbps) == ML_SESSION_OK else { return }
        let previous = flowKbps
        flowKbps = kbps
        guard kbps != previous else { return }
        capture.setTargetBitrate(Int(kbps) * 1000)
        if kbps < previous {
            let carried = link > 0 ? "; the link carried \(Int(link)) kbps" : ""
            NativeLog.session.notice("pacing: frames waited \(Int(waited)) ms for the network, up to \(Int(queued / 1024)) KiB queued\(carried, privacy: .public); bitrate \(Int(kbps)) kbps")
        } else if kbps == UInt32(hostTuning.bitrate / 1000) {
            NativeLog.session.notice("pacing: connection clear; bitrate back to \(Int(kbps)) kbps")
        }
    }
    func hostStats(_ interval: NativeInterval) -> NativeStats {
        var stats: NativeStats = [
            .captureFps: interval.rate("captured_frames"), .encodedFps: interval.rate("encoded_frames"),
            .skippedFps: interval.rate("skipped_capture_frames"), .droppedFps: interval.rate("encoder_dropped_frames"),
            .failedFrames: interval.delta("encoder_failed_frames"), .keyframes: interval.delta("encoded_keyframes"),
            .sentMbps: interval.rate("sent_video_bytes") * 8 / 1_000_000, .inFlight: Double(capture?.inFlightCount ?? 0),
            .bitrateMbps: Double(currentBitrate) / 1_000_000, .fpsCap: Double(hostTuning.fps),
            .queueWaitMs: interval.delta("queue_wait_ms"), .sendQueueKib: (interval.maxima["send_queue_bytes"] ?? 0) / 1024,
            .encodeMsMax: interval.maxima["encode_ms"] ?? 0, .sendMsMax: interval.maxima["video_send_ms"] ?? 0
        ]
        stats[.encodeMs] = interval.average("encode_ms_total", per: "encoded_frames")
        stats[.sendMs] = interval.average("video_send_ms_total", per: "sent_video_frames")
        stats[.frameKib] = interval.average("sent_video_bytes", per: "sent_video_frames").map { $0 / 1024 }
        stats[.pixelWidth] = interval.values["capture_pixel_width"]
        stats[.pixelHeight] = interval.values["capture_pixel_height"]
        stats[.captureMs] = interval.average("capture_ms_total", per: "captured_frames")
        if lastLinkKbps > 0 { stats[.linkMbps] = Double(lastLinkKbps) / 1000 }
        return stats
    }
    func viewerStats(_ interval: NativeInterval) -> NativeStats {
        var stats: NativeStats = [
            .receivedFps: interval.rate("received_video_frames"), .receivedMbps: interval.rate("received_video_bytes") * 8 / 1_000_000,
            .decodedFps: interval.rate("decoded_frames"), .presentedFps: interval.rate("presented_frames"),
            .keyframeRequests: interval.delta("keyframe_requests"), .decoderOverflows: interval.delta("decoder_overflows"),
            .decodeMsMax: interval.maxima["decode_ms"] ?? 0
        ]
        stats[.decodeMs] = interval.average("decode_ms_total", per: "decoded_frames")
        stats[.rttMs] = interval.values["network_round_trip_ms"]
        stats[.latencyMs] = interval.values["latency_ms"]
        stats[.latencyMsP95] = interval.values["latency_ms_p95"]
        stats[.toViewerMs] = interval.values["to_viewer_ms"]
        stats[.displayWaitMs] = interval.values["display_wait_ms"]
        stats[.clockErrorMs] = interval.values["clock_error_ms"]
        return stats
    }

    /// Runs only on an arriving measurement/peer event or a one-shot expiry.
    /// Local rates and latency flow from the receive/decode/presentation path;
    /// host values flow from its authenticated telemetry messages.
    func updateViewerDiagnostics(_ channel: NativeSessionChannel, interval: NativeInterval) {
        let (host, age) = channel.latestPeerStats()
        let totals = interval.values
        var local = viewerStats(interval)
        while let first = liveLatencies.first, first.at < uptime - 1 { liveLatencies.removeFirst() }
        var latency = NativeLatencyWindow()
        for sample in liveLatencies { latency.add(sample.value) }
        let summary = latency.summary
        local[.latencyMs] = summary?.p50; local[.latencyMsP95] = summary?.p95
        local[.toViewerMs] = summary?.toViewer; local[.displayWaitMs] = summary?.displayWait
        var snapshot = NativeViewerDiagnostics()
        snapshot.connected = true
        snapshot.state = firstFrame ? (viewerInputEnabled ? "Connected · control enabled" : "Connected · view only") : "Waiting for video"
        snapshot.local = local; snapshot.host = host; snapshot.hostAge = age; snapshot.totals = totals
        if let codec = totals["video_codec"] {
            snapshot.codec = codec == Double(ML_CODEC_HEVC) ? NativeVideoCodec.hevc.name : NativeVideoCodec.h264.name
        }
        if totals["decoded_frames", default: 0] > 0 { snapshot.hardwareDecoder = decoder?.hardwareDecoder }
        if let video = viewerWindow?.video {
            let size = video.convertToBacking(video.bounds).size
            snapshot.videoArea = "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) px"
        }
        snapshot.protocolVersion = channel.transport.protocolVersion; snapshot.peerVersion = viewerPeerVersion
        snapshot.audio = audioPlayer?.snapshot(); snapshot.soundEnabled = playsSound
        viewerWindow?.updateDiagnostics(snapshot)
        let fps = local[.presentedFps, default: 0]
        let rate = fps < 0.5 ? "no new frames displayed" : String(format: "%.0f fps as the screen changes", fps)
        let timing = summary.map { String(format: "%.0f ms latency", $0.p50) }
            ?? local[.rttMs].map { String(format: "%.0f ms RTT", $0) } ?? "checking connection"
        let size = viewerWindow?.video.geometry.map { " · \($0.pixelWidth)×\($0.pixelHeight)" } ?? ""
        let route: String
        switch channel.transport.transportPath {
        case 1: route = " · Internet direct"
        case 2: route = " · Relayed"
        case 3: route = " · Internet"
        default: route = ""
        }
        viewerWindow?.status.stringValue = "\(viewerInputEnabled ? "Connected" : "View only") · \(rate) · \(timing)\(size)\(route)"
    }

    func saveDiagnostics(_ measurements: NativeSessionMeasurements?) {
        guard let measurements else { showError("Connect a native session before saving diagnostics."); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Mooring-diagnostics.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try measurements.report().write(to: url, options: .atomic) }
        catch { showError("Could not save diagnostics: \(error.localizedDescription)") }
    }
    func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Mooring connection"; alert.informativeText = MooringPrivacy.redact(message); alert.runModal()
    }
}
