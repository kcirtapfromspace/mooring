// Synthetic public-API feasibility probe. Never captures a screen or sends input.
// Build with: xcrun swiftc -O scripts/encode-probe.swift -o /tmp/maclink-encode-probe
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreText

let width = 1280
let height = 720
let frameCount = 6

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

final class OutputCollector {
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []
    private var statuses: [Int32] = []
    private var dropped = 0

    func append(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        lock.lock()
        defer { lock.unlock() }
        statuses.append(status)
        if flags.contains(.frameDropped) { dropped += 1 }
        if status == noErr, let sample, CMSampleBufferDataIsReady(sample) { samples.append(sample) }
    }

    func snapshot() -> ([CMSampleBuffer], [Int32], Int) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, statuses, dropped)
    }
}

func fourCC(_ code: FourCharCode) -> String {
    String(bytes: [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)], encoding: .ascii) ?? String(code)
}

func frame(_ index: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ]
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                    attributes as CFDictionary, &pixelBuffer)
    guard status == kCVReturnSuccess, let pixelBuffer else { throw ProbeError("CVPixelBufferCreate: \(status)") }
    let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard lockStatus == kCVReturnSuccess else { throw ProbeError("CVPixelBufferLockBaseAddress: \(lockStatus)") }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { throw ProbeError("Cannot create synthetic bitmap context") }
    context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.96, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // Fine saturated edges make chroma subsampling visible in later fidelity work.
    for x in 0..<256 {
        context.setFillColor(x % 2 == 0 ? CGColor(red: 1, green: 0, blue: 0, alpha: 1) : CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 40 + x, y: 80, width: 1, height: 256))
    }
    for row in 0..<12 {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, CGFloat(10 + row), nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: row % 2 == 0 ? 0.05 : 0.8, green: 0.2, blue: 0.7, alpha: 1)
        ]
        let text = NSAttributedString(string: "MacLink synthetic frame \(index): let pixel = rgb(255, 0, 255); 0123456789", attributes: attributes)
        context.textPosition = CGPoint(x: 40, y: 380 + row * 25)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
    context.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 500 + index * 30, y: 150, width: 100, height: 100))
    return pixelBuffer
}

func copiedProperty(_ session: VTCompressionSession, _ key: CFString) -> [String: Any] {
    var value: Unmanaged<CFTypeRef>?
    let status = VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault, valueOut: &value)
    var result: [String: Any] = ["status": status]
    if let value { result["value"] = value.takeRetainedValue() }
    return result
}

func annexB(_ samples: [CMSampleBuffer]) throws -> (Data, String) {
    guard let first = samples.first, let format = CMSampleBufferGetFormatDescription(first) else { throw ProbeError("No encoded output format") }
    let codec = CMFormatDescriptionGetMediaSubType(format)
    guard codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_H264 else { throw ProbeError("Unsupported actual output codec \(fourCC(codec))") }
    var result = Data()
    let startCode = Data([0, 0, 0, 1])
    var parameterCount = 0
    var headerLength: Int32 = 0
    let queryStatus = codec == kCMVideoCodecType_HEVC
        ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterCount, nalUnitHeaderLengthOut: &headerLength)
        : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterCount, nalUnitHeaderLengthOut: &headerLength)
    guard queryStatus == noErr, (1...4).contains(headerLength), parameterCount > 0 else { throw ProbeError("Parameter-set query: \(queryStatus), length \(headerLength)") }
    for index in 0..<parameterCount {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = codec == kCMVideoCodecType_HEVC
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
        guard status == noErr, let pointer, size > 0 else { throw ProbeError("Parameter-set copy: \(status)") }
        result.append(startCode)
        result.append(pointer, count: size)
    }
    for sample in samples {
        guard let sampleFormat = CMSampleBufferGetFormatDescription(sample), CMFormatDescriptionGetMediaSubType(sampleFormat) == codec,
            let block = CMSampleBufferGetDataBuffer(sample) else { throw ProbeError("Missing sample data or changing codec") }
        let size = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: size)
        let status = bytes.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: buffer.baseAddress!)
        }
        guard status == noErr else { throw ProbeError("CMBlockBufferCopyDataBytes: \(status)") }
        var offset = 0
        while offset < size {
            guard size - offset >= Int(headerLength) else { throw ProbeError("Truncated NAL length") }
            var nalSize = 0
            for _ in 0..<Int(headerLength) { nalSize = (nalSize << 8) | Int(bytes[offset]); offset += 1 }
            guard nalSize > 0, nalSize <= size - offset else { throw ProbeError("Invalid NAL size \(nalSize)") }
            result.append(startCode)
            result.append(contentsOf: bytes[offset..<(offset + nalSize)])
            offset += nalSize
        }
    }
    return (result, fourCC(codec))
}

func ffprobe(_ url: URL, executable: String) -> [String: Any] {
    guard FileManager.default.isExecutableFile(atPath: executable) else { return ["error": "ffprobe is unavailable at \(executable)"] }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries", "stream=codec_name,codec_long_name,profile,pix_fmt,width,height,nb_read_frames,has_b_frames", "-of", "json", url.path]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var result: [String: Any] = ["exit_status": process.terminationStatus]
        if let report = try? JSONSerialization.jsonObject(with: data) { result["report"] = report }
        else { result["unparsed_stdout"] = String(data: data, encoding: .utf8) ?? "" }
        if !errorData.isEmpty { result["stderr"] = String(data: errorData, encoding: .utf8) ?? "" }
        return result
    } catch { return ["error": String(describing: error)] }
}

func probe(id: String, desiredProfile: String?, lowLatency: Bool, outputDirectory: URL, ffprobePath: String) -> [String: Any] {
    var result: [String: Any] = ["id": id, "requested_codec": "HEVC", "requested_profile": desiredProfile ?? "encoder_default",
        "requested_low_latency": lowLatency, "required_hardware": true, "width": width, "height": height,
        "input_pixel_format": "32BGRA", "requested_frames": frameCount]
    var specification: [String: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
    if lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true }
    let collector = OutputCollector()
    let reference = Unmanaged.passUnretained(collector).toOpaque()
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
        encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: { refcon, _, status, flags, sample in
            guard let refcon else { return }
            Unmanaged<OutputCollector>.fromOpaque(refcon).takeUnretainedValue().append(status: status, flags: flags, sample: sample)
        }, refcon: reference, compressionSessionOut: &session)
    result["creation_status"] = status
    guard status == noErr, let session else { result["outcome"] = "creation_failed"; return result }
    defer {
        VTCompressionSessionInvalidate(session)
        withExtendedLifetime(collector) {}
    }
    var dictionary: CFDictionary?
    result["property_query_status"] = VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &dictionary)
    let propertyDictionary = dictionary as? [String: Any]
    let profileDictionary = propertyDictionary?[kVTCompressionPropertyKey_ProfileLevel as String] as? [String: Any]
    let profiles = profileDictionary?[kVTPropertySupportedValueListKey as String] as? [String] ?? []
    result["advertised_profiles"] = profiles
    if let desiredProfile {
        // Only pass values returned by this session's public supported-property query.
        guard let advertised = profiles.first(where: { $0 == desiredProfile }) else {
            result["outcome"] = "requested_profile_not_advertised"
            return result
        }
        let profileStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: advertised as CFString)
        result["set_profile_status"] = profileStatus
        guard profileStatus == noErr else { result["outcome"] = "profile_rejected"; return result }
    }
    let realtimeStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    let reorderStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    result["realtime_status"] = realtimeStatus
    result["disable_frame_reordering_status"] = reorderStatus
    guard realtimeStatus == noErr, reorderStatus == noErr else { result["outcome"] = "required_property_rejected"; return result }
    let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
    result["prepare_status"] = prepareStatus
    guard prepareStatus == noErr else { result["outcome"] = "prepare_failed"; return result }
    result["reported_profile"] = copiedProperty(session, kVTCompressionPropertyKey_ProfileLevel)
    result["hardware_encoder"] = copiedProperty(session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder)
    result["encoder_id"] = copiedProperty(session, kVTCompressionPropertyKey_EncoderID)
    var encodeStatuses: [Int32] = []
    do {
        for index in 0..<frameCount {
            let pixelBuffer = try frame(index)
            var flags = VTEncodeInfoFlags()
            let encodeStatus = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 60), duration: CMTime(value: 1, timescale: 60),
                frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flags)
            encodeStatuses.append(encodeStatus)
            if encodeStatus != noErr { break }
        }
        let completeStatus = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        result["complete_status"] = completeStatus
        result["encode_statuses"] = encodeStatuses
        let (samples, callbacks, dropped) = collector.snapshot()
        result["callback_statuses"] = callbacks
        result["output_frames"] = samples.count
        result["dropped_frames"] = dropped
        guard !samples.isEmpty else { result["outcome"] = "no_encoded_frames"; return result }
        let (bytes, actualCodec) = try annexB(samples)
        result["actual_output_fourcc"] = actualCodec
        result["codec_matches_request"] = actualCodec == "hvc1" || actualCodec == "hev1"
        result["encoded_bytes"] = bytes.count
        let fileName = "\(id).\(actualCodec == "avc1" ? "h264" : "hevc")"
        let url = outputDirectory.appendingPathComponent(fileName)
        try bytes.write(to: url, options: .atomic)
        result["annex_b_file"] = fileName
        let inspected = ffprobe(url, executable: ffprobePath)
        result["ffprobe"] = inspected
        if let inspection = inspected["report"] as? [String: Any],
           let streams = inspection["streams"] as? [[String: Any]],
           let pixelFormat = streams.first?["pix_fmt"] as? String,
           let desiredProfile {
            result["requested_profile_chroma_matches_output"] = desiredProfile.contains("444")
                ? pixelFormat.hasPrefix("yuv444") : pixelFormat.hasPrefix("yuv420")
        }
        result["outcome"] = completeStatus == noErr && dropped == 0 && samples.count == frameCount && encodeStatuses.allSatisfy { $0 == noErr } && callbacks.allSatisfy { $0 == noErr }
            ? "encoded_all_synthetic_frames" : "partial_output"
    } catch { result["outcome"] = "probe_error"; result["error"] = String(describing: error) }
    return result
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory() + "maclink-encode-probe", isDirectory: true)
let ffprobePath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/opt/homebrew/bin/ffprobe"
do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let report: [String: Any] = [
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "generated_at_utc": ISO8601DateFormatter().string(from: Date()),
        "scope": "Six generated 1280x720 BGRA frames per case. No screen capture, remote input, external downloads, fidelity measurement, or performance benchmark. Frame timestamps request 60 fps; real-time 60 fps throughput is not established.",
        "output_directory": outputDirectory.path,
        "ffprobe_executable": ffprobePath,
        "cases": [
            probe(id: "hevc_main", desiredProfile: "HEVC_Main_AutoLevel", lowLatency: false, outputDirectory: outputDirectory, ffprobePath: ffprobePath),
            probe(id: "hevc_main444", desiredProfile: "HEVC_Main444_AutoLevel", lowLatency: false, outputDirectory: outputDirectory, ffprobePath: ffprobePath),
            probe(id: "hevc_low_latency_default", desiredProfile: nil, lowLatency: true, outputDirectory: outputDirectory, ffprobePath: ffprobePath),
            probe(id: "hevc_low_latency_main", desiredProfile: "HEVC_Main_AutoLevel", lowLatency: true, outputDirectory: outputDirectory, ffprobePath: ffprobePath),
            probe(id: "hevc_low_latency_main444", desiredProfile: "HEVC_Main444_AutoLevel", lowLatency: true, outputDirectory: outputDirectory, ffprobePath: ffprobePath)
        ]
    ]
    let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(bytes)
    print("")
} catch {
    FileHandle.standardError.write(Data("encode-probe: \(error)\n".utf8))
    exit(1)
}
