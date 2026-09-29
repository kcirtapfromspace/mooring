// Real hardware codec -> encrypted loopback transport -> hardware decoder.
// Synthetic pixels only. No Keychain, ScreenCaptureKit, permission or input APIs.
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
        let writer = DispatchQueue(label: "native-test-writer")
        func fail(_ message: String) { lock.lock(); if error == nil { error = message }; lock.unlock(); decoded.signal(); returnedControl.signal(); accepted.signal() }
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
                    case .input(let event)? where event.kind == .releaseAll: state.returnedControl.signal()
                    case .telemetry(.tuning(let tuning))? where tuning.fps == 30: state.receivedTuning.signal()
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
                    case .control(.geometry): continue
                    case .telemetry(.stats(let stats)) where stats[.captureFps] == 60: state.receivedStats.signal()
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
        print("Native encrypted stream: \(total)/\(total) 1080p frames, return controls and live telemetry both ways; hardware decode verified. Report: \(path)")
        token.cancel(); client.close(); server.close()
    }
}
