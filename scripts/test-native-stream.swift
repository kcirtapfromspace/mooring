// Real hardware codec -> encrypted loopback transport -> hardware decoder.
// Synthetic pixels only. No Keychain, ScreenCaptureKit, permission or input APIs.
import AppKit
import Foundation
import CoreGraphics
import CoreVideo
import CoreMedia
import CoreText

@main
struct NativeStreamIntegration {
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var server: NativeTransport?
        var error: String?
        var frames = 0
        var bytes = 0
        var encodeMS: [Double] = []
        var roundTripMS: [Double] = []
        var began = ProcessInfo.processInfo.systemUptime
        let accepted = DispatchSemaphore(value: 0)
        let decoded = DispatchSemaphore(value: 0)
        let returnedControl = DispatchSemaphore(value: 0)
        let receivedStats = DispatchSemaphore(value: 0)
        let receivedTuning = DispatchSemaphore(value: 0)
        let hostClipboard = DispatchSemaphore(value: 0)
        let largeClipboard = DispatchSemaphore(value: 0)
        let finalMove = DispatchSemaphore(value: 0)
        var moves = 0
        let viewerClipboard = DispatchSemaphore(value: 0)
        let writer = DispatchQueue(label: "native-test-writer")
        func fail(_ message: String) { lock.lock(); if error == nil { error = message }; lock.unlock(); decoded.signal(); returnedControl.signal(); accepted.signal() }
    }
    /// Protocol 5 end to end: both sides announce HEVC 4:4:4, the host sees the
    /// viewer's Hello and streams HEVC, and the viewer decodes 4:4:4 frames.
    static func hevcStream() throws -> (frames: Int, medianLatency: Double) {
        try require(NativeCodecSupport.probeHEVC444(), "HEVC 4:4:4 self-test")
        try require(NativeAudioSupport.probeOpus(), "Opus self-test")
        ml_capabilities_set(UInt64(ML_CAPABILITY_HEVC_444) | UInt64(ML_CAPABILITY_CURSOR) | UInt64(ML_CAPABILITY_AUDIO)
                            | UInt64(ML_CAPABILITY_LATENCY))
        defer { ml_capabilities_set(0) }
        let identity = try NativeHostIdentity.create()
        let code = try NativePairingCode.forHost(address: "127.0.0.1", computerName: "Synthetic HEVC test", identity: identity)
        let listener = try NativeTransport.listen(identity: identity, bindAddress: "127.0.0.1", port: 0)
        defer { listener.close() }
        let accepted = DispatchSemaphore(value: 0), lock = NSLock()
        var server: NativeTransport?
        DispatchQueue.global().async {
            let transport = try? listener.accept()
            lock.lock(); server = transport; lock.unlock(); accepted.signal()
        }
        let client = try NativeTransport.connect(address: "127.0.0.1", code: code, port: listener.listeningPort)
        defer { client.close() }
        try require(accepted.wait(timeout: .now() + 5) == .success, "HEVC session accept")
        lock.lock(); let host = server; lock.unlock()
        guard let host else { throw NativeSessionError(message: "HEVC session did not authenticate") }
        defer { host.close() }
        try require(client.protocolVersion == 5 && host.protocolVersion == 5, "Both sides negotiate protocol 5")
        guard case .control(.hello(let viewerCapabilities))? = try host.receive() else { throw NativeSessionError(message: "Host expected the viewer's Hello") }
        guard case .control(.hello)? = try client.receive() else { throw NativeSessionError(message: "Viewer expected the host's Hello") }
        try require(viewerCapabilities & UInt64(ML_CAPABILITY_HEVC_444) != 0 && host.peerCapabilities == viewerCapabilities,
                    "The host learns the viewer decodes HEVC 4:4:4")
        // The pointer shape crosses too: a 2x PNG with its size and hotspot in points.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 18, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let png = rep.representation(using: .png, properties: [:]) else { throw NativeSessionError(message: "Cursor PNG") }
        let pointer = NativeCursorImage(width: 9, height: 18, hotspotX: 4, hotspotY: 9, png: png)
        try host.send(.cursor(pointer))
        guard case .cursor(let received)? = try client.receive(), received == pointer, let shape = received.cursor,
              shape.image.size == NSSize(width: 9, height: 18), shape.hotSpot == NSPoint(x: 4, y: 9) else {
            throw NativeSessionError(message: "The viewer did not receive the host's pointer shape")
        }
        // Clock placement: a ping answered with the host's clock. Both ends are
        // this Mac, so the offset must be within the error bound of zero.
        let clock = NativeClockSync()
        for id in UInt64(1)...3 {
            // Hosts skip pings less than 250 ms apart.
            if id > 1 { Thread.sleep(forTimeInterval: 0.26) }
            let sent = NativeClock.nowUs
            try client.send(.control(.ping(id)))
            guard case .control(.ping(id))? = try host.receive() else { throw NativeSessionError(message: "Host expected a ping") }
            try host.send(.control(.clock(id, hostUs: NativeClock.nowUs)))
            guard case .control(.clock(id, let hostUs))? = try client.receive() else { throw NativeSessionError(message: "Viewer expected a clock reply") }
            clock.add(sentUs: sent, receivedUs: NativeClock.nowUs, hostUs: hostUs)
        }
        guard let placed = clock.estimate else { throw NativeSessionError(message: "The clocks were not placed") }
        try require(placed.offsetUs.magnitude <= placed.errorUs + 1_000, "A same-Mac clock offset is within its bound of zero")
        // Sound: 100 ms of a tone, encoded to Opus on the host, decoded and
        // buffered for playout on the viewer. Nothing is played.
        let soundEncoder = try NativeAudioEncoder(), soundDecoder = try NativeAudioDecoder(), gate = NativeAudioSendGate()
        var sent: [NativeAudioPacket] = []
        soundEncoder.onPacket = { payload in
            guard let sequence = gate.admit() else { return }
            sent.append(NativeAudioPacket(sequence: sequence, frames: 480, channels: 2, payload: payload))
            gate.finished()
        }
        for start in stride(from: 0, to: 4_800, by: 480) {
            soundEncoder.append(interleaved: (start..<(start + 480)).flatMap { index -> [Float] in
                let value = Float(sin(2 * Double.pi * 440 * Double(index) / 48_000)) * 0.3
                return [value, value]
            })
        }
        try require(sent.count == 10, "The host encodes 10 ms Opus packets")
        for packet in sent { try host.send(.audio(packet)) }
        let playout = NativeAudioBuffer()
        var energy: Float = 0
        for expected in sent {
            guard case .audio(let received)? = try client.receive(), received == expected else {
                throw NativeSessionError(message: "The viewer did not receive the host's sound in order")
            }
            soundDecoder.decode(received.payload) { samples in
                energy += samples.reduce(0) { $0 + $1 * $1 }
                playout.write(samples)
            }
        }
        try require(energy > 1 && playout.snapshot().buffered >= 4_000, "The viewer decodes the host's sound for playout")
        let encoder = try NativeVideoEncoder(width: 1920, height: 1080, framesPerSecond: 60, bitrate: 25_000_000, codec: .hevc)
        let decoder = NativeVideoDecoder()
        defer { encoder.stop(); decoder.stop() }
        let decoded = DispatchSemaphore(value: 0), sendQueue = DispatchQueue(label: "hevc-writer")
        var failure: String?
        var latencies: [Double] = []
        decoder.onFrame = { buffer in
            // Decoded stands in for shown here: there is no display in this test.
            if let timing = NativeFrameTiming.read(buffer),
               let latency = clock.latency(NativeFrameTiming(hostUs: timing.0, decodeStartUs: timing.1, decodedUs: timing.2, presentedUs: timing.2)) {
                lock.lock(); latencies.append(latency.total); lock.unlock()
            }
            decoded.signal()
        }
        decoder.onError = { message in lock.lock(); failure = message; lock.unlock(); decoded.signal() }
        encoder.onEncodedFrame = { frame, release in
            sendQueue.async { defer { release() }; do { try host.send(.video(frame.packet)) } catch { lock.lock(); failure = error.localizedDescription; lock.unlock() } }
        }
        try host.send(.control(.geometry(NativeDisplayGeometry(x: 0, y: 0, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080),
                                         inputEnabled: false)))
        guard case .control(.geometry)? = try client.receive() else { throw NativeSessionError(message: "Viewer expected geometry") }
        let total = 30
        for index in 0..<total {
            let pixels = try frame(index, width: 1920, height: 1080)
            // Stamped with the capture clock, as ScreenCaptureKit display times are.
            try require(encoder.encode(pixels, presentationTime: CMClockGetTime(CMClockGetHostTimeClock())), "HEVC admission")
            var packet: NativeVideoPacket?
            while packet == nil { if case .video(let received)? = try client.receive() { packet = received } }
            try require(packet?.codec == .hevc && packet?.chromaFormat == 3, "The viewer receives HEVC 4:4:4")
            _ = decoder.decode(packet!)
            try require(decoded.wait(timeout: .now() + 3) == .success, "HEVC decode over the session")
            lock.lock(); let error = failure; lock.unlock()
            if let error { throw NativeSessionError(message: error) }
        }
        lock.lock(); let measured = latencies; lock.unlock()
        try require(measured.count == total && measured.allSatisfy { $0 < 500 },
                    "Every frame reports capture-to-decoded latency across the session")
        return (total, NativeLatencyWindow.percentile(measured, 0.5) ?? 0)
    }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NativeSessionError(message: message) }
    }
    static func frame(_ index: Int, width: Int, height: Int) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        try require(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &result) == kCVReturnSuccess, "Synthetic pixel allocation failed")
        let pixel = result!
        CVPixelBufferLockBaseAddress(pixel, []); defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw NativeSessionError(message: "Synthetic context allocation failed")
        }
        context.setFillColor(CGColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 17, nil)
        for row in 0..<32 {
            let text = NSAttributedString(string: String(format: "%02d  fn stream(frame: PixelBuffer) -> Result<Frame> { draw_text(); }", row), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: row % 2 == 0 ? 0.2 : 0.9, green: 0.8, blue: 0.9, alpha: 1)])
            context.textPosition = CGPoint(x: 25, y: 35 + row * 27 + index % 5)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        context.setFillColor(CGColor(red: 0.95, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 1100 + index * 3 % 500, y: 120 + index % 100, width: 100, height: 220))
        return pixel
    }
    static func main() {
        do { try run() } catch { fputs("Native stream integration failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    /// Synthetic clipboards: never read from or written to a real pasteboard.
    static let viewerCopy = NativeClipboardContent(text: "Copied on the viewer ✓", rtf: Data("{\\rtf1\\ansi viewer}".utf8),
                                                   png: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]))
    static let hostCopy = NativeClipboardContent(text: String(repeating: "host ", count: 600_000))
    static let largeCopy = NativeClipboardContent(text: String(repeating: "v", count: Int(ML_CLIPBOARD_MAX_BYTES)))
    static func run() throws {
        let state = State(), token = NativeRunToken()
        let identity = try NativeHostIdentity.create()
        let code = try NativePairingCode.forHost(address: "127.0.0.1", computerName: "Synthetic test", identity: identity)
        let listener = try NativeTransport.listen(identity: identity, bindAddress: "127.0.0.1", port: 0)
        defer { token.cancel(); listener.close(); state.server?.close() }
        DispatchQueue.global().async {
            do {
                guard let server = try listener.accept() else { state.fail("Accept timed out"); return }
                state.server = server; state.accepted.signal()
                while token.isActive {
                    switch try server.receive() {
                    case .control(.hello)?: continue // protocol 5 opens with the viewer's capabilities
                    case .input(let event)? where event.kind == .releaseAll: state.returnedControl.signal()
                    case .telemetry(.tuning(let tuning))? where tuning.fps == 30: state.receivedTuning.signal()
                    case .clipboard(let content)? where content == viewerCopy: state.hostClipboard.signal()
                    case .clipboard(let content)? where content == largeCopy: state.largeClipboard.signal()
                    case .input(let event)? where event.kind == .pointerMove:
                        state.lock.lock(); state.moves += 1; state.lock.unlock()
                        if event.x == 1 { state.finalMove.signal() }
                    case nil: continue
                    default: state.fail("Unexpected return message"); return
                    }
                }
            } catch { if token.isActive { state.fail(error.localizedDescription) } }
        }
        let client = try NativeTransport.connect(address: "127.0.0.1", code: code, port: listener.listeningPort)
        defer { client.close() }
        try require(state.accepted.wait(timeout: .now() + 5) == .success, "Encrypted accept deadline")
        try require(state.error == nil && state.server != nil, "Authenticated session did not complete")
        let server = state.server!
        let decoder = NativeVideoDecoder()
        let encoder = try NativeVideoEncoder(width: 1920, height: 1080, framesPerSecond: 60, bitrate: 16_000_000)
        defer { encoder.stop(); decoder.stop() }
        decoder.onError = { state.fail($0) }
        decoder.onNeedsKeyframe = { encoder.requestKeyframe() }
        decoder.onFrame = { pixel in
            guard CVPixelBufferGetWidth(pixel) == 1920 && CVPixelBufferGetHeight(pixel) == 1080 else { state.fail("Decoded geometry mismatch"); return }
            state.lock.lock(); state.frames += 1; state.lock.unlock()
            state.decoded.signal()
        }
        encoder.onError = { state.fail($0) }
        encoder.onEncodedFrame = { frame, release in
            state.writer.async {
                defer { release() }
                do {
                    try server.send(.video(frame.packet))
                    state.lock.lock(); state.bytes += frame.packet.wireSize; state.encodeMS.append(frame.metrics.encode_ms); state.lock.unlock()
                } catch { state.fail(error.localizedDescription) }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                while token.isActive {
                    guard let message = try client.receive() else { continue }
                    switch message {
                    case .control(.geometry), .control(.hello): continue
                    case .telemetry(.stats(let stats)) where stats[.captureFps] == 60: state.receivedStats.signal()
                    case .clipboard(let content) where content == hostCopy: state.viewerClipboard.signal()
                    case .video(let packet):
                        _ = decoder.decode(packet)
                        // An ordinary typed event, never passed to CGEvent injection.
                        try client.send(.input(NativeInputEvent(kind: .releaseAll)))
                    default: state.fail("Unexpected forward data"); return
                    }
                }
            } catch { if token.isActive { state.fail(error.localizedDescription) } }
        }
        // Rust requires display geometry before any video reaches a viewer.
        try server.send(.control(.geometry(NativeDisplayGeometry(x: 0, y: 0, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080),
                                           inputEnabled: false)))
        let total = 120, began = ProcessInfo.processInfo.systemUptime
        for index in 0..<total {
            let delay = began + Double(index) / 60 - ProcessInfo.processInfo.systemUptime
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let input = try frame(index, width: 1920, height: 1080)
            let started = ProcessInfo.processInfo.systemUptime
            try require(encoder.encode(input, presentationTime: CMTime(value: Int64(index), timescale: 60)), "Bounded encoder admission failed")
            try require(state.decoded.wait(timeout: .now() + 5) == .success, "Encrypted frame did not decode")
            try require(state.returnedControl.wait(timeout: .now() + 5) == .success, "Return control did not arrive")
            state.roundTripMS.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
            if let error = state.error { throw NativeSessionError(message: error) }
        }
        state.writer.sync {}
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        // Live telemetry crosses the same encrypted session: stats to the viewer, tuning to the host.
        try server.send(.telemetry(.stats([.captureFps: 60, .encodeMs: 9.5])))
        try require(state.receivedStats.wait(timeout: .now() + 5) == .success, "Host stats reach the viewer")
        var tuning = MLTuning(); tuning.fps = 30
        try client.send(.telemetry(.tuning(NativeTuning(raw: tuning))))
        try require(state.receivedTuning.wait(timeout: .now() + 5) == .success, "Viewer tuning reaches the host")
        // The shared clipboard crosses both ways: all three kinds to the host, 3 MB of text to the viewer.
        try require(viewerCopy.isValid && hostCopy.isValid, "Rust accepts the synthetic clipboards")
        try client.send(.clipboard(viewerCopy))
        try require(state.hostClipboard.wait(timeout: .now() + 5) == .success, "The viewer's clipboard reaches the host")
        try server.send(.clipboard(hostCopy))
        try require(state.viewerClipboard.wait(timeout: .now() + 5) == .success, "The host's clipboard reaches the viewer")
        // Pointer moves queued behind a 4 MiB clipboard merge, so the send queue
        // cannot overflow, and the newest position always arrives.
        let channel = NativeSessionChannel(client)
        channel.onFailure = { state.fail("Channel failed: \($0)") }
        channel.send(.clipboard(largeCopy))
        for index in 1...1000 { channel.send(.input(try NativeInputEvent(kind: .pointerMove, x: Double(index) / 1000, y: 0.5))) }
        try require(state.largeClipboard.wait(timeout: .now() + 5) == .success, "The largest clipboard crosses a channel")
        try require(state.finalMove.wait(timeout: .now() + 5) == .success, "The newest pointer position arrives")
        state.lock.lock(); let moves = state.moves; state.lock.unlock()
        try require(channel.token.isActive && moves < 1000, "Queued pointer moves merge instead of filling the queue (\(moves) sent)")
        try require(state.frames == total && encoder.snapshot.encoded_frames == total && decoder.hardwareDecoder, "Incomplete native pipeline")
        let sorted = state.roundTripMS.sorted(), encodes = state.encodeMS.sorted()
        let report: [String: Any] = ["kind": "synthetic encrypted loopback, not display/input latency", "frames": state.frames,
            "width": 1920, "height": 1080, "elapsed_seconds": elapsed, "completed_fps": Double(total) / elapsed,
            "encode_mean_ms": encodes.reduce(0, +) / Double(encodes.count), "encode_p95_ms": encodes[Int(Double(encodes.count - 1) * 0.95)],
            "encode_transport_decode_and_return_control_p50_ms": sorted[sorted.count / 2],
            "encode_transport_decode_and_return_control_p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
            "video_bytes": state.bytes, "decoder_hardware_verified": true, "encoder_hardware_evidence": encoder.snapshot.hardware_encoder_evidence,
            "screen_capture_performed": false, "input_injection_performed": false, "keychain_accessed": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let path = CommandLine.arguments.dropFirst().first ?? "target/native-stream-loopback.json"
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        let hevc = try hevcStream()
        print("Native encrypted stream: \(total)/\(total) 1080p frames, return controls, live telemetry and clipboards both ways; " +
              "then a pointer shape, 100 ms of Opus sound and \(hevc.frames) HEVC 4:4:4 frames after a protocol 5 capability exchange, " +
              String(format: "with clocks placed and a %.1f ms median from capture timestamp to decoded; hardware decode verified. Report: %@", hevc.medianLatency, path))
        token.cancel(); client.close(); server.close()
    }
}
