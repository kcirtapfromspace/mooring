import AppKit
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreVideo
import MetalKit
import CoreImage

/// Logical CoreGraphics display bounds plus encoded pixel dimensions. The
/// bounds rule is Rust's (ml_display_geometry_validate).
struct NativeDisplayGeometry: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let pixelWidth: Int
    let pixelHeight: Int

    init(x: Double, y: Double, width: Double, height: Double, pixelWidth: Int, pixelHeight: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
    init(_ raw: MLDisplayGeometry) {
        self.init(x: raw.x, y: raw.y, width: raw.width, height: raw.height,
                  pixelWidth: Int(raw.pixel_width), pixelHeight: Int(raw.pixel_height))
    }
    var raw: MLDisplayGeometry {
        MLDisplayGeometry(x: x, y: y, width: width, height: height,
                          pixel_width: UInt32(clamping: pixelWidth), pixel_height: UInt32(clamping: pixelHeight))
    }
    var isValid: Bool { var raw = raw; return ml_display_geometry_validate(&raw) == ML_SESSION_OK }
}

struct NativeMediaMetrics: Codable {
    var encode_ms: Double = 0
    var encoded_frames: UInt64 = 0
    var skipped_capture_frames: UInt64 = 0
    var encoded_bytes: UInt64 = 0
    var hardware_encoder: Bool = false
    var hardware_encoder_evidence: String = ""
    var pixel_width: Int = 0
    var pixel_height: Int = 0
    var target_bitrate: Int = 0
    /// Frames the hardware rate control skipped; the chain continues without them.
    var dropped_frames: UInt64 = 0
    /// Frames that failed and restarted the chain with a keyframe.
    var failed_frames: UInt64 = 0
    var keyframes: UInt64 = 0
    var encode_ms_total: Double = 0
}

struct NativeEncodedFrame {
    let packet: NativeVideoPacket
    let metrics: NativeMediaMetrics
    var keyframe: Bool { packet.keyframe }
    var sequence: UInt64 { packet.sequence }
}

struct NativeMediaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// One H.264 access unit: SPS/PPS parameter sets and an AVCC bitstream with
/// four-byte NAL lengths. Rust owns the MLV1 wire format and its validation:
/// dimensions, sizes, allowed NAL types, and a keyframe flag matching the IDR.
struct NativeVideoPacket {
    static let headerBytes = Int(ML_VIDEO_HEADER_BYTES)
    static let maximumBytes = Int(ML_SESSION_MAX_VIDEO)
    let width: Int
    let height: Int
    let sequence: UInt64
    let timestamp: UInt64
    let keyframe: Bool
    let sps: Data
    let pps: Data
    let avcc: Data

    init(width: Int, height: Int, sequence: UInt64, timestamp: UInt64, keyframe: Bool, sps: Data, pps: Data, avcc: Data) {
        self.width = width; self.height = height; self.sequence = sequence; self.timestamp = timestamp
        self.keyframe = keyframe; self.sps = sps; self.pps = pps; self.avcc = avcc
    }
    init(header: MLVideoHeader, sps: Data, pps: Data, avcc: Data) {
        self.init(width: Int(header.width), height: Int(header.height), sequence: header.sequence,
                  timestamp: header.timestamp_us, keyframe: header.keyframe == 1, sps: sps, pps: pps, avcc: avcc)
    }
    static func validDimensions(_ width: Int, _ height: Int) -> Bool {
        guard let width = UInt32(exactly: width), let height = UInt32(exactly: height) else { return false }
        return ml_video_dimensions_validate(width, height) == ML_SESSION_OK
    }
    var wireSize: Int { Self.headerBytes + sps.count + pps.count + avcc.count }
    func validate() throws {
        guard withFrame({ ml_video_frame_validate($0) }) == ML_SESSION_OK else {
            throw NativeMediaError("Encoded frame exceeds the native stream limits or contains unsupported H.264.")
        }
    }
    /// Borrows the components as an MLVideoFrame for one Rust call.
    func withFrame<Result>(_ body: (UnsafePointer<MLVideoFrame>) -> Result) -> Result {
        var header = MLVideoHeader()
        header.sequence = sequence; header.timestamp_us = timestamp; header.keyframe = keyframe ? 1 : 0
        header.width = UInt32(clamping: width); header.height = UInt32(clamping: height)
        return sps.withUnsafeBytes { sps in
            pps.withUnsafeBytes { pps in
                avcc.withUnsafeBytes { avcc in
                    var frame = MLVideoFrame(header: header,
                        sps: sps.bindMemory(to: UInt8.self).baseAddress, sps_length: sps.count,
                        pps: pps.bindMemory(to: UInt8.self).baseAddress, pps_length: pps.count,
                        avcc: avcc.bindMemory(to: UInt8.self).baseAddress, avcc_length: avcc.count)
                    return body(&frame)
                }
            }
        }
    }
    func formatDescription() throws -> CMVideoFormatDescription {
        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointers in
                    sizes.withUnsafeBufferPointer { sizes in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                            parameterSetCount: 2, parameterSetPointers: pointers.baseAddress!, parameterSetSizes: sizes.baseAddress!,
                            nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                    }
                }
            }
        }
        guard status == noErr, let format else { throw NativeMediaError("Invalid H.264 configuration (\(status)).") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width == width, dimensions.height == height else { throw NativeMediaError("H.264 dimensions disagree with the packet header.") }
        return format
    }
}

/// Thread-safe admission. At most two frames are in flight, from admission until
/// the transport finishes writing them, so the next frame can encode while the
/// previous one is still being sent. Configure callbacks before encoding. Call
/// release after the transport finishes writing an access unit, including on
/// failure. Never drop an encoded P frame and continue the same chain:
/// requestKeyframe() after a failed transport send.
final class NativeVideoEncoder {
    static let maxInFlight = 2
    /// Consecutive failed frames tolerated before reporting a fatal error.
    static let failureBudget = 8
    var onEncodedFrame: ((NativeEncodedFrame, @escaping () -> Void) -> Void)?
    var onError: ((String) -> Void)?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "MacLink.native.encode", qos: .userInteractive)
    private var session: VTCompressionSession?
    private var active = true
    private var outstanding = Set<UInt64>()
    private var nextToken: UInt64 = 0
    private var consecutiveFailures = 0
    private var forceKeyframe = true
    /// Wire sequence, assigned only to frames actually emitted: a frame rate
    /// control skips must not look like a gap to the viewer.
    private var sequence: UInt64 = 0
    private var metrics = NativeMediaMetrics()
    private var targetBitrate: Int
    private var appliedBitrate: Int
    private var inFlightLimit = NativeVideoEncoder.maxInFlight
    private var targetFrameRate: Int
    private var appliedFrameRate: Int
    private var targetKeyframeSeconds: Int
    private var appliedKeyframeSeconds: Int
    let width: Int
    let height: Int

    init(width: Int, height: Int, framesPerSecond: Int = 60, bitrate: Int = 25_000_000, keyframeSeconds: Int = 2) throws {
        guard NativeVideoPacket.validDimensions(width, height), (1...60).contains(framesPerSecond),
              (1_000_000...80_000_000).contains(bitrate) else { throw NativeMediaError("Unsupported video encoder configuration.") }
        guard (1...10).contains(keyframeSeconds) else { throw NativeMediaError("Unsupported keyframe interval.") }
        self.width = width; self.height = height
        targetBitrate = bitrate; appliedBitrate = bitrate
        targetFrameRate = framesPerSecond; appliedFrameRate = framesPerSecond
        targetKeyframeSeconds = keyframeSeconds; appliedKeyframeSeconds = keyframeSeconds
        let specification: [String: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true
        ]
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { throw NativeMediaError("Hardware H.264 encoder is unavailable (\(status)).") }
        session = created
        do {
            for (key, value) in [
                (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue as CFTypeRef),
                (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse as CFTypeRef),
                (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel as CFTypeRef),
                (kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber),
                (kVTCompressionPropertyKey_ExpectedFrameRate, framesPerSecond as CFNumber),
                (kVTCompressionPropertyKey_MaxKeyFrameInterval, (framesPerSecond * keyframeSeconds) as CFNumber),
                (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, keyframeSeconds as CFNumber),
                (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2 as CFTypeRef),
                (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2 as CFTypeRef),
                (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as CFTypeRef)
            ] {
                let result = VTSessionSetProperty(created, key: key, value: value)
                guard result == noErr else { throw NativeMediaError("H.264 encoder rejected required configuration (\(result)).") }
            }
            // Optional on some encoders; low-latency mode and no reordering are
            // required above. No caller-side queue relies on this hint.
            _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
            let prepare = VTCompressionSessionPrepareToEncodeFrames(created)
            guard prepare == noErr else { throw NativeMediaError("Hardware encoder preparation failed (\(prepare)).") }
            var hardware: Unmanaged<CFTypeRef>?
            let hardwareStatus = VTSessionCopyProperty(created, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                    allocator: kCFAllocatorDefault, valueOut: &hardware)
            let hardwareValue = hardware?.takeRetainedValue()
            // Apple's low-latency H.264 session on this OS does not expose the
            // optional UsingHardware property (-12900). The required-hardware
            // creation specification is a documented fail-if-unavailable
            // contract. Never accept an explicit false or another query error.
            guard (hardwareStatus == noErr && (hardwareValue as? Bool) == true) || hardwareStatus == kVTPropertyNotSupportedErr else {
                throw NativeMediaError("Hardware encoder verification failed (status \(hardwareStatus), value \(String(describing: hardwareValue))).")
            }
            metrics.hardware_encoder_evidence = hardwareStatus == noErr ? "session_property" : "required_hardware_specification"
            metrics.hardware_encoder = true; metrics.pixel_width = width; metrics.pixel_height = height; metrics.target_bitrate = bitrate
        } catch { VTCompressionSessionInvalidate(created); session = nil; throw error }
    }
    deinit { if let session { VTCompressionSessionInvalidate(session) } }
    var snapshot: NativeMediaMetrics { lock.lock(); defer { lock.unlock() }; return metrics }
    var inFlightCount: Int { lock.lock(); defer { lock.unlock() }; return outstanding.count }
    /// Live settings take effect on the next encoded frame.
    func setFrameRate(_ framesPerSecond: Int) {
        lock.lock(); targetFrameRate = min(60, max(1, framesPerSecond)); lock.unlock()
    }
    func setKeyframeSeconds(_ seconds: Int) {
        lock.lock(); targetKeyframeSeconds = min(10, max(1, seconds)); lock.unlock()
    }
    /// 1 serializes encoding and sending; 2 overlaps them.
    func setInFlightLimit(_ limit: Int) {
        lock.lock(); inFlightLimit = min(Self.maxInFlight, max(1, limit)); lock.unlock()
    }
    func setTargetBitrate(_ bitsPerSecond: Int) {
        lock.lock(); targetBitrate = min(80_000_000, max(1_000_000, bitsPerSecond)); lock.unlock()
    }
    func requestKeyframe() { lock.lock(); forceKeyframe = true; lock.unlock() }
    @discardableResult
    func encode(_ image: CVPixelBuffer, presentationTime: CMTime) -> Bool {
        lock.lock()
        guard active, outstanding.count < inFlightLimit else { if active { metrics.skipped_capture_frames &+= 1 }; lock.unlock(); return false }
        guard CVPixelBufferGetWidth(image) == width, CVPixelBufferGetHeight(image) == height,
              presentationTime.isNumeric, presentationTime.seconds >= 0 else { lock.unlock(); return false }
        nextToken &+= 1
        let token = nextToken, keyframe = forceKeyframe, bitrate = targetBitrate
        let frameRate = targetFrameRate, keyframeSeconds = targetKeyframeSeconds
        outstanding.insert(token)
        forceKeyframe = false
        lock.unlock()
        let began = ProcessInfo.processInfo.systemUptime
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let active = self.active; self.lock.unlock()
            guard active, let session = self.session else { self.release(token); return }
            if frameRate != self.appliedFrameRate || keyframeSeconds != self.appliedKeyframeSeconds {
                let applied = [
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber),
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (frameRate * keyframeSeconds) as CFNumber),
                    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: keyframeSeconds as CFNumber)
                ].allSatisfy { $0 == noErr }
                if applied { self.appliedFrameRate = frameRate; self.appliedKeyframeSeconds = keyframeSeconds }
            }
            if bitrate != self.appliedBitrate {
                let result = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
                if result == noErr { self.appliedBitrate = bitrate }
            }
            let properties = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
            let result = VTCompressionSessionEncodeFrame(session, imageBuffer: image,
                presentationTimeStamp: presentationTime, duration: CMTime(value: 1, timescale: Int32(frameRate)),
                frameProperties: properties, infoFlagsOut: nil) { [weak self] status, flags, sample in
                    self?.queue.async { [weak self] in
                        self?.encoded(status: status, flags: flags, sample: sample, token: token, began: began)
                    }
                }
            if result != noErr { self.fail(token, "H.264 encode failed (\(result)).") }
        }
        return true
    }
    /// Idempotent, including after stop.
    private func release(_ token: UInt64) {
        lock.lock(); outstanding.remove(token); lock.unlock()
    }
    /// A failed frame is skipped and the chain restarts with a keyframe. Only a
    /// run of failures, such as an invalidated session, ends the session. The
    /// failure consumes a sequence number: a later frame already in the encoder
    /// may reference the lost one, so the viewer must see a gap and wait for
    /// the keyframe rather than decode against the wrong reference.
    private func fail(_ token: UInt64, _ message: String) {
        requestKeyframe()
        lock.lock()
        outstanding.remove(token); consecutiveFailures += 1; metrics.failed_frames &+= 1; sequence &+= 1
        let report = active && consecutiveFailures >= Self.failureBudget
        lock.unlock()
        if report { onError?(message) }
    }
    private func encoded(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?, token: UInt64, began: TimeInterval) {
        lock.lock(); let valid = active && outstanding.contains(token); lock.unlock()
        guard valid else { return }
        if status == noErr && flags.contains(.frameDropped) {
            // Real-time rate control skipped this frame; the encoder's references
            // are unchanged, so the chain continues without it.
            lock.lock(); outstanding.remove(token); metrics.dropped_frames &+= 1; lock.unlock()
            return
        }
        guard status == noErr, let sample, CMSampleBufferDataIsReady(sample) else {
            fail(token, "Hardware encoder did not produce a complete frame (\(status))."); return
        }
        do {
            guard let format = CMSampleBufferGetFormatDescription(sample),
                  CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264,
                  let block = CMSampleBufferGetDataBuffer(sample) else { throw NativeMediaError("Encoder output is not H.264.") }
            var parameterSets: [Data] = []
            for index in 0..<2 {
                var pointer: UnsafePointer<UInt8>?, size = 0, count = 0
                var headerLength: Int32 = 0
                let result = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &headerLength)
                guard result == noErr, let pointer, (1...4096).contains(size), count == 2, headerLength == 4 else {
                    throw NativeMediaError("Unsupported H.264 parameter sets.")
                }
                parameterSets.append(Data(bytes: pointer, count: size))
            }
            let size = CMBlockBufferGetDataLength(block)
            guard size > 0, size <= NativeVideoPacket.maximumBytes else { throw NativeMediaError("Encoded video frame is too large.") }
            var bytes = Data(count: size)
            let result = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            guard result == noErr else { throw NativeMediaError("Could not copy the encoded frame.") }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard timestamp.isFinite, timestamp >= 0, timestamp < Double(UInt64.max) / 1_000_000 else { throw NativeMediaError("Invalid capture timestamp.") }
            try NativeVideoPacket(width: width, height: height, sequence: 0, timestamp: UInt64(timestamp * 1_000_000),
                keyframe: keyframe, sps: parameterSets[0], pps: parameterSets[1], avcc: bytes).validate()
            lock.lock()
            sequence &+= 1; consecutiveFailures = 0
            let packet = NativeVideoPacket(width: width, height: height, sequence: sequence,
                timestamp: UInt64(timestamp * 1_000_000), keyframe: keyframe,
                sps: parameterSets[0], pps: parameterSets[1], avcc: bytes)
            metrics.encode_ms = max(0, (ProcessInfo.processInfo.systemUptime - began) * 1000)
            let milliseconds = max(0, (ProcessInfo.processInfo.systemUptime - began) * 1000)
            metrics.encoded_frames &+= 1; metrics.encoded_bytes &+= UInt64(packet.wireSize); metrics.target_bitrate = appliedBitrate
            metrics.encode_ms_total += milliseconds
            if keyframe { metrics.keyframes &+= 1 }
            let report = metrics
            lock.unlock()
            guard let callback = onEncodedFrame else { release(token); return }
            callback(NativeEncodedFrame(packet: packet, metrics: report)) { [weak self] in self?.release(token) }
        } catch { fail(token, error.localizedDescription) }
    }
    func stop(completion: (() -> Void)? = nil) {
        lock.lock(); active = false; outstanding.removeAll(); lock.unlock()
        queue.async { [self] in
            if let session { VTCompressionSessionInvalidate(session); self.session = nil }
            completion?()
        }
    }
}

/// Start/stop on the main thread after an explicit user action. Geometry and
/// start completion run on main; encoded frames/errors run on media queues.
final class NativeCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onGeometry: ((NativeDisplayGeometry) -> Void)?
    var onEncodedFrame: ((NativeEncodedFrame, @escaping () -> Void) -> Void)?
    var onError: ((String) -> Void)?
    private let captureQueue = DispatchQueue(label: "MacLink.native.capture", qos: .userInteractive)
    private let encoderLock = NSLock()
    private var encoder: NativeVideoEncoder?
    private var captureIdentity: ObjectIdentifier?
    private var captureDisplay: CGDirectDisplayID?
    private var captureGeometry: NativeDisplayGeometry?
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var showsCursor: Bool
    private var generation: UInt64 = 0
    private var starting = false
    private let maxPixelWidth: Int
    private let maxPixelHeight: Int
    private var framesPerSecond: Int
    private var bitrate: Int
    private var keyframeSeconds: Int
    private var inFlightLimit: Int
    /// Called on the capture queue for each complete captured frame.
    var onCapturedFrame: (() -> Void)?

    init(maxPixelWidth: Int = 3840, maxPixelHeight: Int = 2160, framesPerSecond: Int = 60, showsCursor: Bool = true,
         bitrate: Int = 25_000_000, keyframeSeconds: Int = 2, inFlightLimit: Int = NativeVideoEncoder.maxInFlight) {
        self.bitrate = min(80_000_000, max(1_000_000, bitrate))
        self.keyframeSeconds = min(10, max(1, keyframeSeconds))
        self.inFlightLimit = min(NativeVideoEncoder.maxInFlight, max(1, inFlightLimit))
        self.showsCursor = showsCursor
        self.maxPixelWidth = min(3840, max(16, maxPixelWidth))
        self.maxPixelHeight = min(2160, max(16, maxPixelHeight))
        self.framesPerSecond = min(60, max(1, framesPerSecond))
        super.init()
    }
    func start(completion: @escaping (Result<NativeDisplayGeometry, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard NativePrivacyGuard.mayShareNow() else { completion(.failure(NativeMediaError("Sharing requires an active, unlocked user session."))); return }
        guard !starting, stream == nil else { completion(.failure(NativeMediaError("Screen capture is already running."))); return }
        starting = true; generation &+= 1
        let token = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.generation == token else { completion(.failure(NativeMediaError("Screen capture was cancelled."))); return }
                guard NativePrivacyGuard.mayShareNow() else { throw NativeMediaError("The local user session is no longer eligible for sharing.") }
                let identifier = CGMainDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == identifier }),
                      let displayMode = CGDisplayCopyDisplayMode(identifier) else { throw NativeMediaError("The main display is unavailable.") }
                let logical = CGDisplayBounds(identifier)
                let scale = min(1, Double(self.maxPixelWidth) / Double(displayMode.pixelWidth), Double(self.maxPixelHeight) / Double(displayMode.pixelHeight))
                let width = max(16, Int(Double(displayMode.pixelWidth) * scale) / 2 * 2)
                let height = max(16, Int(Double(displayMode.pixelHeight) * scale) / 2 * 2)
                let geometry = NativeDisplayGeometry(x: logical.minX, y: logical.minY, width: logical.width, height: logical.height, pixelWidth: width, pixelHeight: height)
                guard geometry.isValid else { throw NativeMediaError("Unsupported main-display geometry.") }
                let encoder = try NativeVideoEncoder(width: width, height: height, framesPerSecond: self.framesPerSecond,
                                                     bitrate: self.bitrate, keyframeSeconds: self.keyframeSeconds)
                encoder.setInFlightLimit(self.inFlightLimit)
                encoder.onEncodedFrame = { [weak self] frame, release in
                    guard let callback = self?.onEncodedFrame else { release(); return }
                    callback(frame, release)
                }
                encoder.onError = { [weak self] in self?.onError?($0) }
                self.setEncoder(encoder)
                let configuration = SCStreamConfiguration()
                configuration.width = width; configuration.height = height
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(self.framesPerSecond))
                configuration.queueDepth = 3; configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = self.showsCursor; configuration.capturesAudio = false
                configuration.scalesToFit = true; configuration.colorSpaceName = CGColorSpace.sRGB
                configuration.captureResolution = .best
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
                self.stream = stream; self.configuration = configuration
                self.setStreamMetadata(stream, display: identifier, geometry: geometry)
                // Enqueue control geometry before SCK can deliver the first frame.
                self.onGeometry?(geometry)
                try await stream.startCapture()
                guard self.generation == token else { try? await stream.stopCapture(); completion(.failure(NativeMediaError("Screen capture was cancelled."))); return }
                self.starting = false
                completion(.success(geometry))
            } catch {
                if self.generation == token { self.starting = false; self.stream = nil; self.takeEncoder()?.stop() }
                completion(.failure(error))
            }
        }
    }
    private func takeEncoder() -> NativeVideoEncoder? {
        encoderLock.lock(); defer { encoderLock.unlock() }
        let result = encoder; encoder = nil; captureIdentity = nil; captureDisplay = nil; captureGeometry = nil
        return result
    }
    private func currentEncoder() -> NativeVideoEncoder? { encoderLock.lock(); defer { encoderLock.unlock() }; return encoder }
    private func setEncoder(_ value: NativeVideoEncoder) { encoderLock.lock(); encoder = value; encoderLock.unlock() }
    private func setStreamMetadata(_ stream: SCStream, display: CGDirectDisplayID, geometry: NativeDisplayGeometry) {
        encoderLock.lock(); captureIdentity = ObjectIdentifier(stream); captureDisplay = display; captureGeometry = geometry; encoderLock.unlock()
    }
    func stop() {
        precondition(Thread.isMainThread)
        generation &+= 1; starting = false
        takeEncoder()?.stop()
        if let stream { self.stream = nil; configuration = nil; Task { try? await stream.stopCapture() } }
    }
    /// Draw this Mac's pointer into the video only when it is not the viewer's
    /// own pointer; a controlling viewer already shows it locally.
    func setShowsCursor(_ show: Bool) {
        precondition(Thread.isMainThread)
        guard show != showsCursor else { return }
        showsCursor = show
        guard let stream, let configuration else { return }
        configuration.showsCursor = show
        stream.updateConfiguration(configuration) { _ in }
    }
    func requestKeyframe() { currentEncoder()?.requestKeyframe() }
    var inFlightCount: Int { currentEncoder()?.inFlightCount ?? 0 }
    /// The running encoder's cumulative counters; nil before start and after stop.
    var encoderMetrics: NativeMediaMetrics? { currentEncoder()?.snapshot }
    /// Updates the capture interval and the encoder's expected rate.
    func setFrameRate(_ fps: Int) {
        precondition(Thread.isMainThread)
        framesPerSecond = min(60, max(1, fps)); currentEncoder()?.setFrameRate(framesPerSecond)
        guard let stream, let configuration else { return }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(framesPerSecond))
        stream.updateConfiguration(configuration) { _ in }
    }
    func setKeyframeSeconds(_ seconds: Int) {
        precondition(Thread.isMainThread)
        keyframeSeconds = min(10, max(1, seconds)); currentEncoder()?.setKeyframeSeconds(keyframeSeconds)
    }
    func setInFlightLimit(_ limit: Int) {
        precondition(Thread.isMainThread)
        inFlightLimit = min(NativeVideoEncoder.maxInFlight, max(1, limit)); currentEncoder()?.setInFlightLimit(inFlightLimit)
    }
    func setTargetBitrate(_ bitsPerSecond: Int) {
        precondition(Thread.isMainThread)
        bitrate = min(80_000_000, max(1_000_000, bitsPerSecond)); currentEncoder()?.setTargetBitrate(bitrate)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        encoderLock.lock(); let matches = captureIdentity == ObjectIdentifier(stream); encoderLock.unlock()
        guard matches else { return }
        takeEncoder()?.stop()
        onError?("Screen capture stopped: \(error.localizedDescription)")
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else { return }
        encoderLock.lock()
        let current = captureIdentity == ObjectIdentifier(stream) ? encoder : nil
        let display = captureDisplay, geometry = captureGeometry
        encoderLock.unlock()
        guard let current, let display, let geometry else { return }
        guard NativePrivacyGuard.mayShareNow() else {
            takeEncoder()?.stop()
            onError?("Screen sharing stopped because the local user session became unavailable or locked.")
            return
        }
        guard sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let bounds = CGDisplayBounds(display)
        guard CGMainDisplayID() == display, bounds.minX == geometry.x, bounds.minY == geometry.y,
              bounds.width == geometry.width, bounds.height == geometry.height else {
            takeEncoder()?.stop()
            onError?("Display geometry changed. Reconnect to restore accurate remote input.")
            return
        }
        onCapturedFrame?()
        _ = current.encode(image, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

/// One synchronous hardware decode in progress plus at most one pending packet.
/// Packets arrive validated by Rust or from the local encoder.
/// Overflow discards the pending chain and requests an IDR. Render callbacks run
/// on the decoder queue; use NativeVideoView.display(), which safely coalesces.
final class NativeVideoDecoder {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onError: ((String) -> Void)?
    var onNeedsKeyframe: (() -> Void)?
    /// Milliseconds for each successfully decoded frame, on the decode queue.
    var onDecoded: ((Double) -> Void)?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "MacLink.native.decode", qos: .userInteractive)
    private var overflowCount: UInt64 = 0
    /// Packets discarded because decoding fell behind, since the decoder started.
    var overflows: UInt64 { lock.lock(); defer { lock.unlock() }; return overflowCount }
    private var active = true
    private var busy = false
    private var pending: NativeVideoPacket?
    private var discontinuity = true
    private var discontinuityEpoch: UInt64 = 0
    private var requestOutstanding = false
    private var requestedAt = -Double.infinity
    private var consecutiveFailures = 0
    /// Consecutive failed decodes tolerated before reporting a fatal error.
    static let failureBudget = 5
    private let keyframeRetryInterval: TimeInterval
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var sps = Data(), pps = Data()
    private var lastSequence: UInt64?
    private var usingHardwareDecoder = false
    var hardwareDecoder: Bool { lock.lock(); defer { lock.unlock() }; return usingHardwareDecoder }
    var pendingFrameCount: Int { lock.lock(); defer { lock.unlock() }; return pending == nil ? 0 : 1 }

    /// The host ignores keyframe requests less than 0.5 s apart, so the retry
    /// interval must exceed that or a dropped request stalls until the next IDR.
    init(keyframeRetryInterval: TimeInterval = 0.75) { self.keyframeRetryInterval = keyframeRetryInterval }
    /// Call with lock held. At most one request per retry interval while waiting.
    private func claimKeyframeRequestLocked() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard !requestOutstanding || now - requestedAt >= keyframeRetryInterval else { return false }
        requestOutstanding = true; requestedAt = now
        return true
    }

    @discardableResult
    func decode(_ packet: NativeVideoPacket) -> Bool {
        lock.lock()
        guard active else { lock.unlock(); return false }
        if busy {
            guard pending == nil else {
                pending = nil; discontinuity = true; discontinuityEpoch &+= 1; overflowCount &+= 1
                let notify = claimKeyframeRequestLocked(); lock.unlock()
                if notify { onNeedsKeyframe?() }
                return false
            }
            pending = packet; lock.unlock(); return true
        }
        busy = true; lock.unlock()
        queue.async { [weak self] in self?.process(packet) }
        return true
    }
    /// A failed frame restarts the chain with a keyframe; waiting for that
    /// keyframe is not a failure. Only a run of failures is reported as fatal.
    private func notifyRecovery(_ message: String, reportError: Bool = true) {
        lock.lock()
        guard active else { lock.unlock(); return }
        discontinuity = true; discontinuityEpoch &+= 1; pending = nil
        if reportError { consecutiveFailures += 1 }
        let fatal = reportError && consecutiveFailures >= Self.failureBudget
        let notify = claimKeyframeRequestLocked(); lock.unlock()
        if notify { onNeedsKeyframe?() }
        if fatal { onError?(message) }
    }
    private func process(_ packet: NativeVideoPacket) {
        defer {
            lock.lock()
            let next = active ? pending : nil; pending = nil
            if next == nil { busy = false }
            lock.unlock()
            if let next { queue.async { [weak self] in self?.process(next) } }
        }
        lock.lock(); let active = self.active, broken = discontinuity, epoch = discontinuityEpoch; lock.unlock()
        guard active else { return }
        do {
            let sequenceGap = lastSequence.map { $0 == UInt64.max || packet.sequence != $0 + 1 } ?? true
            let newFormat = packet.sps != sps || packet.pps != pps
            if broken || sequenceGap || newFormat {
                guard packet.keyframe else { notifyRecovery("Waiting for a keyframe after a video discontinuity.", reportError: false); return }
                try createSession(packet)
                lock.lock()
                let recovered = self.active && discontinuityEpoch == epoch
                if recovered { discontinuity = false; requestOutstanding = false }
                lock.unlock()
                guard recovered else { return }
            }
            guard let session, let format else { throw NativeMediaError("No decoder configuration is available.") }
            var block: CMBlockBuffer?
            var result = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: packet.avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: packet.avcc.count, flags: 0, blockBufferOut: &block)
            guard result == noErr, let block else { throw NativeMediaError("Could not allocate a compressed frame.") }
            result = packet.avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: packet.avcc.count) }
            guard result == noErr else { throw NativeMediaError("Could not copy a compressed frame.") }
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(min(packet.timestamp, UInt64(Int64.max))), timescale: 1_000_000), decodeTimeStamp: .invalid)
            var size = packet.avcc.count
            result = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
            guard result == noErr, let sample else { throw NativeMediaError("Could not create a decode sample.") }
            var output: CVPixelBuffer?, outputStatus: OSStatus = noErr
            // Both async/temporal flags are clear: Apple guarantees the callback
            // finishes before this call returns. No asynchronous output backlog.
            let began = ProcessInfo.processInfo.systemUptime
            result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, flags, image, _, _ in
                outputStatus = status
                if !flags.contains(.frameDropped) { output = image }
            }
            guard result == noErr, outputStatus == noErr, let output,
                  CVPixelBufferGetWidth(output) == packet.width, CVPixelBufferGetHeight(output) == packet.height else {
                throw NativeMediaError("Hardware video decode failed (\(result)/\(outputStatus)).")
            }
            lastSequence = packet.sequence
            lock.lock(); let deliver = self.active && !discontinuity; if deliver { consecutiveFailures = 0 }; lock.unlock()
            if deliver { onDecoded?((ProcessInfo.processInfo.systemUptime - began) * 1000); onFrame?(output) }
        } catch { notifyRecovery(error.localizedDescription) }
    }
    private func createSession(_ packet: NativeVideoPacket) throws {
        let format = try packet.formatDescription()
        if let session { VTDecompressionSessionInvalidate(session); self.session = nil }
        let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true] as CFDictionary
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var created: VTDecompressionSession?
        let result = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: specification, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created)
        guard result == noErr, let created else { throw NativeMediaError("Hardware H.264 decoder is unavailable (\(result)).") }
        _ = VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var hardware: Unmanaged<CFTypeRef>?
        guard VTSessionCopyProperty(created, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault, valueOut: &hardware) == noErr, (hardware?.takeRetainedValue() as? Bool) == true else {
            VTDecompressionSessionInvalidate(created); throw NativeMediaError("Hardware decoding could not be verified.")
        }
        session = created; self.format = format; sps = packet.sps; pps = packet.pps; lastSequence = nil
        lock.lock(); usingHardwareDecoder = true; lock.unlock()
    }
    func stop() {
        lock.lock(); active = false; pending = nil; lock.unlock()
        queue.async { [self] in if let session { VTDecompressionSessionInvalidate(session); self.session = nil }; format = nil }
    }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}

/// GPU rendering through Core Image's Metal backend. Decoded frames coalesce in
/// one slot; display() may be called from any queue. AppKit geometry/input is main.
class NativeVideoView: MTKView, MTKViewDelegate {
    var geometry: NativeDisplayGeometry? {
        didSet {
            if geometry?.isValid == true { frameLock.lock(); acceptsFrames = true; frameLock.unlock() }
        }
    }
    var onPresented: (() -> Void)?
    private let frameLock = NSLock()
    private var pendingImage: CVPixelBuffer?
    private var displayScheduled = false
    private var hasUpdate = false
    private var acceptsFrames = true
    private var clearPending = false
    private var currentImage: CVPixelBuffer?
    private var context: CIContext?
    private var commands: MTLCommandQueue?
    private var gpuBusy = false
    private var renderDirty = true
    private var revision: UInt64 = 0
    private var submittedRevision: UInt64 = 0
    private var presentationEpoch: UInt64 = 0
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private(set) var displayedVideoRect = NSRect.zero
    override var isFlipped: Bool { true }

    override init(frame: NSRect, device: MTLDevice?) {
        let device = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: device)
        framebufferOnly = false; colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        isPaused = true; enableSetNeedsDisplay = true; autoResizeDrawable = true
        if let device { context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false]); commands = device.makeCommandQueue() }
        delegate = self
    }
    convenience init(frame: NSRect = .zero) { self.init(frame: frame, device: nil) }
    required init(coder: NSCoder) { fatalError("NativeVideoView does not support storyboard initialization") }
    func display(_ image: CVPixelBuffer) {
        frameLock.lock()
        guard acceptsFrames else { frameLock.unlock(); return }
        pendingImage = image; hasUpdate = true
        let schedule = !displayScheduled; displayScheduled = true; frameLock.unlock()
        if schedule { DispatchQueue.main.async { [weak self] in self?.consumeNewestFrame() } }
    }
    private func consumeNewestFrame() {
        frameLock.lock()
        guard hasUpdate else { displayScheduled = false; frameLock.unlock(); return }
        let shouldClear = clearPending && !acceptsFrames
        currentImage = pendingImage; pendingImage = nil; displayScheduled = false; hasUpdate = false; clearPending = false
        frameLock.unlock()
        if shouldClear { geometry = nil; displayedVideoRect = .zero; presentationEpoch &+= 1 }
        revision &+= 1
        renderDirty = true
        needsDisplay = true
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { renderDirty = true; needsDisplay = true }
    func draw(in view: MTKView) {
        if gpuBusy { renderDirty = true; return }
        guard let context, let commands, let drawable = currentDrawable,
              let command = commands.makeCommandBuffer(), drawableSize.width > 0, drawableSize.height > 0 else { return }
        let canvas = CGRect(origin: .zero, size: drawableSize)
        let black = CIImage(color: .black).cropped(to: canvas)
        var output = black
        if let currentImage {
            let image = CIImage(cvPixelBuffer: currentImage)
            let scale = min(drawableSize.width / image.extent.width, drawableSize.height / image.extent.height)
            let width = image.extent.width * scale, height = image.extent.height * scale
            let x = (drawableSize.width - width) / 2, y = (drawableSize.height - height) / 2
            output = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: black)
            displayedVideoRect = NSRect(x: x / drawableSize.width * bounds.width, y: y / drawableSize.height * bounds.height,
                                       width: width / drawableSize.width * bounds.width, height: height / drawableSize.height * bounds.height)
        } else { displayedVideoRect = .zero }
        context.render(output, to: drawable.texture, commandBuffer: command, bounds: canvas, colorSpace: colorSpace)
        let newFrame = currentImage != nil && revision != submittedRevision
        submittedRevision = revision
        let epoch = presentationEpoch
        if newFrame {
            drawable.addPresentedHandler { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.presentationEpoch == epoch else { return }
                    self.onPresented?()
                }
            }
        }
        gpuBusy = true
        renderDirty = false
        command.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.gpuBusy = false
                if self.renderDirty || self.revision != self.submittedRevision { self.needsDisplay = true }
            }
        }
        command.present(drawable); command.commit()
    }
    func remotePoint(for localPoint: NSPoint) -> CGPoint? {
        guard let geometry, geometry.isValid, displayedVideoRect.width > 0, displayedVideoRect.height > 0,
              displayedVideoRect.contains(localPoint) else { return nil }
        return CGPoint(x: geometry.x + (localPoint.x - displayedVideoRect.minX) / displayedVideoRect.width * geometry.width,
                       y: geometry.y + (localPoint.y - displayedVideoRect.minY) / displayedVideoRect.height * geometry.height)
    }
    /// Closes frame admission until the next valid geometry assignment. This
    /// fences late decode callbacks and queued display work after disconnect.
    func clearFrame() {
        frameLock.lock(); pendingImage = nil; acceptsFrames = false; clearPending = true; hasUpdate = true
        let schedule = !displayScheduled; displayScheduled = true; frameLock.unlock()
        if Thread.isMainThread { consumeNewestFrame() }
        else if schedule { DispatchQueue.main.async { [weak self] in self?.consumeNewestFrame() } }
    }
    func clear() { clearFrame() }
}
