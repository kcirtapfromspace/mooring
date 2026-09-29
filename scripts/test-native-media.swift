// Synthetic hardware codec regression. No ScreenCaptureKit capture, permission
// prompts, remote input, or network traffic. Compile with app/NativeMedia.swift.
import Foundation
import CoreVideo
import CoreGraphics
import CoreMedia

@main
struct NativeMediaTests {
    struct Failure: Error, LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    final class Collector {
        let lock = NSLock()
        var encoded: [NativeEncodedFrame] = []
        var decoded = 0
        var errors: [String] = []
        var widths = Set<Int>(), heights = Set<Int>()
        var keyframeRequests = 0
        var heldReleases: [() -> Void] = []
        let firstOutput = DispatchSemaphore(value: 0)
        let decodeOutput = DispatchSemaphore(value: 0)
        func record(_ frame: NativeEncodedFrame) { lock.lock(); encoded.append(frame); lock.unlock() }
        func record(_ buffer: CVPixelBuffer) {
            lock.lock(); decoded += 1; widths.insert(CVPixelBufferGetWidth(buffer)); heights.insert(CVPixelBufferGetHeight(buffer)); lock.unlock()
            decodeOutput.signal()
        }
        func fail(_ message: String) { lock.lock(); errors.append(message); lock.unlock() }
    }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message) }
    }
    static func image(index: Int, width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true] as [String: Any]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw Failure("Create synthetic pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw Failure("Create synthetic bitmap") }
        context.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for row in 0..<20 {
            context.setFillColor(CGColor(red: 0.05, green: 0.1, blue: 0.25, alpha: 1))
            context.fill(CGRect(x: 20, y: 20 + row * 30, width: 400 + row * 20, height: 2))
        }
        context.setFillColor(CGColor(red: 0.9, green: 0.12, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 200 + (index * 7) % max(1, width - 400), y: 150, width: 120, height: 180))
        context.setFillColor(CGColor(red: 0.1, green: 0.55, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 400, y: 500, width: 500, height: 50 + index % 40))
        return buffer
    }
    static func main() {
        do { try run() }
        catch { fputs("NativeMedia test failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        let width = 1920, height = 1080, frames = 120
        let collector = Collector()
        let encoder = try NativeVideoEncoder(width: width, height: height, framesPerSecond: 60, bitrate: 12_000_000)
        let decoder = NativeVideoDecoder()
        defer { encoder.stop(); decoder.stop() }
        encoder.onError = { collector.fail($0) }
        decoder.onError = { collector.fail($0) }
        decoder.onNeedsKeyframe = { collector.lock.lock(); collector.keyframeRequests += 1; collector.lock.unlock(); encoder.requestKeyframe() }
        decoder.onFrame = { collector.record($0) }
        // The first two frames simulate sends that have not finished yet.
        encoder.onEncodedFrame = { frame, release in
            collector.record(frame)
            collector.lock.lock()
            let held = collector.encoded.count <= NativeVideoEncoder.maxInFlight
            if held { collector.heldReleases.append(release) }
            collector.lock.unlock()
            _ = decoder.decode(frame.packet)
            if held { collector.firstOutput.signal() } else { release() }
        }
        for index in 0..<NativeVideoEncoder.maxInFlight {
            let pixels = try image(index: index, width: width, height: height)
            try require(encoder.encode(pixels, presentationTime: CMTime(value: Int64(index), timescale: 60)),
                        "A frame may encode while an earlier one is still sending")
            try require(collector.firstOutput.wait(timeout: .now() + 5) == .success, "Hardware encode timed out")
            try require(collector.decodeOutput.wait(timeout: .now() + 5) == .success, "Hardware decode timed out")
        }
        let blocked = try image(index: 99, width: width, height: height)
        for _ in 0..<100 { try require(!encoder.encode(blocked, presentationTime: CMTime(value: 2, timescale: 60)), "Encode backpressure admitted an extra frame") }
        try require(encoder.inFlightCount == NativeVideoEncoder.maxInFlight && encoder.snapshot.encoded_frames == 2,
                    "Encode/send backlog is bounded at two frames")
        collector.lock.lock(); let releases = collector.heldReleases; collector.heldReleases = []; collector.lock.unlock()
        for release in releases { release(); release() } // Idempotent completion from a transport teardown.
        try require(encoder.inFlightCount == 0, "Released frames free their admission slots")
        let began = ProcessInfo.processInfo.systemUptime
        for index in NativeVideoEncoder.maxInFlight..<frames {
            let scheduled = began + Double(index - 1) / 60
            let delay = scheduled - ProcessInfo.processInfo.systemUptime
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while encoder.inFlightCount > 0 && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.001) }
            if index == 60 { encoder.requestKeyframe(); encoder.setTargetBitrate(16_000_000) }
            let pixel = try image(index: index, width: width, height: height)
            try require(encoder.encode(pixel, presentationTime: CMTime(value: Int64(index), timescale: 60)), "Paced frame admission \(index)")
            try require(decoder.pendingFrameCount <= 1 && encoder.inFlightCount <= 1, "Pipeline queue bound")
        }
        for _ in NativeVideoEncoder.maxInFlight..<frames { try require(collector.decodeOutput.wait(timeout: .now() + 5) == .success, "Paced decode timed out") }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        collector.lock.lock()
        let encoded = collector.encoded, decoded = collector.decoded, errors = collector.errors
        let widths = collector.widths, heights = collector.heights
        collector.lock.unlock()
        try require(errors.isEmpty, errors.first ?? "Media error")
        try require(encoded.count == frames && decoded == frames, "Complete paced hardware round trip")
        try require(widths == [width] && heights == [height], "Actual decoded dimensions")
        try require(encoder.snapshot.hardware_encoder && decoder.hardwareDecoder, "Hardware codec use")
        try require(encoded[0].keyframe && encoded[60].keyframe, "Initial and requested IDR")
        try require(encoded[60].metrics.target_bitrate == 16_000_000, "Live bitrate change")
        var packets: [NativeVideoPacket] = []
        for frame in encoded {
            // Real hardware output must satisfy Rust's packet rules before sending.
            try frame.packet.validate()
            let format = try frame.packet.formatDescription()
            try require(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264, "Actual H.264 output")
            packets.append(frame.packet)
        }
        let firstPacket = packets[0]
        let forged = NativeVideoPacket(width: firstPacket.width, height: firstPacket.height, sequence: 1, timestamp: 0,
            keyframe: false, sps: firstPacket.sps, pps: firstPacket.pps, avcc: firstPacket.avcc)
        do { try forged.validate(); throw Failure("Forged keyframe flag accepted") } catch is NativeMediaError { }
        let mismatched = NativeVideoPacket(width: firstPacket.width - 2, height: firstPacket.height, sequence: 1,
            timestamp: 0, keyframe: true, sps: firstPacket.sps, pps: firstPacket.pps, avcc: firstPacket.avcc)
        do { _ = try mismatched.formatDescription(); throw Failure("SPS/header dimension mismatch accepted") } catch is NativeMediaError { }
        var inBand = firstPacket.avcc
        inBand[4] = 0x67
        let conflicting = NativeVideoPacket(width: firstPacket.width, height: firstPacket.height, sequence: 1,
            timestamp: 0, keyframe: true, sps: firstPacket.sps, pps: firstPacket.pps, avcc: inBand)
        do { try conflicting.validate(); throw Failure("In-band SPS accepted") } catch is NativeMediaError { }
        try require(NativeVideoPacket.validDimensions(3840, 2160) && !NativeVideoPacket.validDimensions(1921, 1080)
                    && !NativeVideoPacket.validDimensions(-2, 16), "Dimension rules come from Rust")
        try testRecovery(encoded)
        try testOverflow(encoded)
        try testFailureBudget(encoded)
        let inspected = try inspectBitstream(packets)
        let stopped = DispatchSemaphore(value: 0)
        encoder.stop { stopped.signal() }
        try require(stopped.wait(timeout: .now() + 3) == .success, "Encoder stop completion")
        let fourK = try testFourK()
        let stats: [String: Any] = ["scope": "Synthetic paced encode/decode only; no screen capture, network or presentation test.",
            "frames": frames, "decoded": decoded, "pixel_width": width, "pixel_height": height,
            "hardware_encoder": encoder.snapshot.hardware_encoder, "hardware_decoder": decoder.hardwareDecoder,
            "hardware_encoder_evidence": encoder.snapshot.hardware_encoder_evidence,
            "paced_seconds": elapsed, "measured_roundtrip_fps": Double(frames - 1) / elapsed,
            "average_encode_ms": encoded.map { $0.metrics.encode_ms }.reduce(0, +) / Double(frames),
            "maximum_encode_send_inflight": NativeVideoEncoder.maxInFlight, "maximum_decoder_pending": 1,
            "decoder_failure_budget": "passed",
            "backpressure_capture_skips": encoder.snapshot.skipped_capture_frames, "ffprobe": inspected,
            "four_k_smoke": fourK, "gap_and_overflow_recovery": "passed"]
        let json = try JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
    static func testRecovery(_ frames: [NativeEncodedFrame]) throws {
        let decoder = NativeVideoDecoder(keyframeRetryInterval: 0.5), output = DispatchSemaphore(value: 0), keyframe = DispatchSemaphore(value: 0)
        defer { decoder.stop() }
        decoder.onFrame = { _ in output.signal() }
        decoder.onNeedsKeyframe = { keyframe.signal() }
        try require(decoder.decode(frames[0].packet), "Recovery initial keyframe admission")
        try require(output.wait(timeout: .now() + 3) == .success, "Recovery initial keyframe decode")
        try require(decoder.decode(frames[1].packet), "Healthy P frame admission")
        try require(output.wait(timeout: .now() + 3) == .success, "Healthy P frame decode")
        try require(decoder.decode(frames[3].packet), "Gap frame admission")
        try require(keyframe.wait(timeout: .now() + 3) == .success, "Gap must request a keyframe")
        try require(output.wait(timeout: .now() + 0.05) == .timedOut, "Gap must not deliver a broken reference frame")
        try require(decoder.decode(frames[4].packet), "Waiting P frame admission")
        try require(keyframe.wait(timeout: .now() + 0.1) == .timedOut, "Keyframe requests stay bounded while waiting")
        // The host drops requests under 0.5 s apart; a still-broken chain asks again.
        Thread.sleep(forTimeInterval: 0.55)
        try require(decoder.decode(frames[5].packet), "Later waiting P frame admission")
        try require(keyframe.wait(timeout: .now() + 3) == .success, "A dropped keyframe request is retried")
        try require(output.wait(timeout: .now() + 0.05) == .timedOut, "Waiting P frames are never displayed")
        try require(decoder.decode(frames[60].packet), "Recovery IDR admission")
        try require(output.wait(timeout: .now() + 3) == .success, "IDR recovers the chain")
        try require(decoder.decode(frames[61].packet), "Recovered P admission")
        try require(output.wait(timeout: .now() + 3) == .success, "Recovered P decode")
        decoder.stop()
        try require(!decoder.decode(frames[62].packet), "Stopped decoder rejects admission")
    }
    static func testOverflow(_ frames: [NativeEncodedFrame]) throws {
        let decoder = NativeVideoDecoder(), entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let recovered = DispatchSemaphore(value: 0), keyframe = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var outputs = 0
        defer { resume.signal(); decoder.stop() }
        decoder.onFrame = { _ in
            lock.lock(); outputs += 1; let first = outputs == 1; lock.unlock()
            if first { entered.signal(); _ = resume.wait(timeout: .now() + 5) } else { recovered.signal() }
        }
        decoder.onNeedsKeyframe = { keyframe.signal() }
        try require(decoder.decode(frames[0].packet), "Overflow test first admission")
        try require(entered.wait(timeout: .now() + 3) == .success, "Overflow test blocked decode callback")
        try require(decoder.decode(frames[1].packet) && decoder.pendingFrameCount == 1, "One pending encoded packet")
        try require(!decoder.decode(frames[2].packet) && decoder.pendingFrameCount == 0, "Overflow clears reference chain")
        try require(keyframe.wait(timeout: .now() + 1) == .success, "Overflow requests IDR")
        try require(decoder.decode(frames[60].packet), "Recovery keyframe occupies the one pending slot")
        resume.signal()
        try require(recovered.wait(timeout: .now() + 3) == .success, "Overflow recovers with IDR")
    }
    /// A keyframe whose header disagrees with its parameter sets always fails.
    static func testFailureBudget(_ frames: [NativeEncodedFrame]) throws {
        let decoder = NativeVideoDecoder(keyframeRetryInterval: 0)
        let requested = DispatchSemaphore(value: 0), output = DispatchSemaphore(value: 0), reported = DispatchSemaphore(value: 0)
        defer { decoder.stop() }
        decoder.onNeedsKeyframe = { requested.signal() }
        decoder.onFrame = { _ in output.signal() }
        decoder.onError = { _ in reported.signal() }
        let good = frames[0].packet
        let bad = NativeVideoPacket(width: good.width - 2, height: good.height, sequence: good.sequence, timestamp: good.timestamp,
                                    keyframe: true, sps: good.sps, pps: good.pps, avcc: good.avcc)
        for _ in 1..<NativeVideoDecoder.failureBudget {
            try require(decoder.decode(bad), "Failing keyframe admission")
            try require(requested.wait(timeout: .now() + 3) == .success, "A failed frame requests a keyframe")
        }
        try require(reported.wait(timeout: .now() + 0.2) == .timedOut, "Isolated decode failures recover instead of ending the session")
        try require(decoder.decode(good), "Good keyframe admission")
        try require(output.wait(timeout: .now() + 3) == .success, "A good keyframe decodes and resets the failure run")
        for _ in 0..<NativeVideoDecoder.failureBudget {
            try require(decoder.decode(bad), "Failing keyframe admission")
            try require(requested.wait(timeout: .now() + 3) == .success, "A failed frame requests a keyframe")
        }
        try require(reported.wait(timeout: .now() + 3) == .success, "A run of decode failures is still reported")
    }
    static func testFourK() throws -> [String: Any] {
        let encoder = try NativeVideoEncoder(width: 3840, height: 2160, framesPerSecond: 60, bitrate: 25_000_000)
        let decoder = NativeVideoDecoder(), output = DispatchSemaphore(value: 0), collector = Collector()
        defer { encoder.stop(); decoder.stop() }
        encoder.onError = { collector.fail($0); output.signal() }
        decoder.onError = { collector.fail($0); output.signal() }
        encoder.onEncodedFrame = { frame, release in collector.record(frame); _ = decoder.decode(frame.packet); release() }
        decoder.onFrame = { buffer in collector.record(buffer); output.signal() }
        for index in 0..<3 {
            let buffer = try image(index: index, width: 3840, height: 2160)
            try require(encoder.encode(buffer, presentationTime: CMTime(value: Int64(index), timescale: 60)), "4K admission")
            try require(output.wait(timeout: .now() + 5) == .success, "4K encode/decode timeout")
        }
        collector.lock.lock()
        let valid = collector.errors.isEmpty && collector.decoded == 3 && collector.widths == [3840] && collector.heights == [2160]
        collector.lock.unlock()
        try require(valid, "Three actual 4K hardware round trips")
        return ["frames": 3, "pixel_width": 3840, "pixel_height": 2160, "last_encode_ms": encoder.snapshot.encode_ms,
                "scope": "Configuration and decode smoke check; not a 4K frame-rate benchmark."]
    }
    static func inspectBitstream(_ packets: [NativeVideoPacket]) throws -> [String: Any] {
        let executable = "/opt/homebrew/bin/ffprobe"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return ["available": false] }
        var annex = Data()
        let start = Data([0, 0, 0, 1])
        for packet in packets {
            if packet.keyframe { annex.append(start); annex.append(packet.sps); annex.append(start); annex.append(packet.pps) }
            let bytes = [UInt8](packet.avcc)
            var offset = 0
            while offset < bytes.count {
                let count = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }; offset += 4
                annex.append(start); annex.append(contentsOf: bytes[offset..<(offset + count)]); offset += count
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maclink-synthetic-" + UUID().uuidString + ".h264")
        try annex.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height,nb_read_frames,has_b_frames,pix_fmt,profile", "-of", "json", url.path]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw Failure("ffprobe timed out") }
        try require(process.terminationStatus == 0, "ffprobe rejected the generated bitstream")
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let stream = (object?["streams"] as? [[String: Any]])?.first else { throw Failure("Missing ffprobe video stream") }
        try require(stream["codec_name"] as? String == "h264" && stream["has_b_frames"] as? Int == 0,
                    "Independent bitstream verification must show H.264 without B frames")
        try require(stream["nb_read_frames"] as? String == String(packets.count), "Independent decoded frame count")
        return stream
    }
}
