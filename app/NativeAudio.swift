import AVFoundation
import AudioToolbox
import CoreMedia
import os

/// The session log (see NativeLog), without depending on the session files.
private let nativeAudioLog = Logger(subsystem: "dev.maclink", category: "session")

/// One Opus packet of the sharing Mac's sound. Rust validates it on send and receive.
struct NativeAudioPacket: Equatable {
    let sequence: UInt32
    let frames: UInt16
    let channels: UInt8
    let payload: Data
}

/// Sound travels as 48 kHz stereo Opus in 10 ms packets, through AudioToolbox's
/// own Opus codec.
enum NativeAudioFormat {
    static let sampleRate = Double(ML_AUDIO_SAMPLE_RATE)
    static let packetFrames = 480
    /// The longest packet the protocol allows, 20 ms.
    static let maxPacketFrames = 960
    static let bitrate: UInt32 = 128_000
    /// Interleaved 32-bit float stereo.
    static var pcm: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
                                    mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    }
    static var opus: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                    mFramesPerPacket: UInt32(packetFrames), mBytesPerFrame: 0, mChannelsPerFrame: 2,
                                    mBitsPerChannel: 0, mReserved: 0)
    }
}

/// One AudioConverterFillComplexBuffer call's input: handed over once, after
/// which the callback reports that nothing more is available yet.
private struct NativeConverterInput {
    var data: UnsafeMutableRawPointer
    var bytes: UInt32
    /// Frames of PCM, or 1 for a compressed packet.
    var packets: UInt32
    var description: UnsafeMutablePointer<AudioStreamPacketDescription>?
    var consumed = false
}
/// Any nonzero status: the converter returns it once it has used the input.
private let nativeNoMoreInput: OSStatus = 1
private func nativeConverterInput(_ converter: AudioConverterRef, _ packets: UnsafeMutablePointer<UInt32>,
                                  _ data: UnsafeMutablePointer<AudioBufferList>,
                                  _ descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                                  _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let input = context?.assumingMemoryBound(to: NativeConverterInput.self), !input.pointee.consumed else {
        packets.pointee = 0
        return nativeNoMoreInput
    }
    input.pointee.consumed = true
    packets.pointee = input.pointee.packets
    data.pointee.mNumberBuffers = 1
    data.pointee.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: input.pointee.bytes, mData: input.pointee.data)
    descriptions?.pointee = input.pointee.description
    return noErr
}

/// Encodes captured sound to 10 ms Opus packets. Use from one queue at a time.
final class NativeAudioEncoder {
    /// Called with each packet, on the appending queue.
    var onPacket: ((Data) -> Void)?
    /// At most 100 ms waits for a full packet; older sound is dropped.
    static let maxPendingFrames = 4_800
    private let converter: AudioConverterRef
    private var pending: [Float] = []
    private var output: [UInt8]
    private(set) var droppedFrames = 0
    private(set) var unsupportedBuffers = 0

    init() throws {
        var pcm = NativeAudioFormat.pcm, opus = NativeAudioFormat.opus
        var created: AudioConverterRef?
        guard AudioConverterNew(&pcm, &opus, &created) == noErr, let converter = created else {
            throw NativeMediaError("This Mac cannot encode Opus sound.")
        }
        var bitrate = NativeAudioFormat.bitrate, maximum: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, size, &bitrate) == noErr,
              AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maximum) == noErr,
              maximum > 0, maximum <= ML_AUDIO_MAX_PAYLOAD else {
            AudioConverterDispose(converter)
            throw NativeMediaError("This Mac's Opus encoder is unsupported.")
        }
        self.converter = converter
        output = [UInt8](repeating: 0, count: Int(maximum))
    }
    deinit { AudioConverterDispose(converter) }

    /// ScreenCaptureKit sound: 48 kHz 32-bit float, mono or stereo, interleaved
    /// or not. Anything else is counted and skipped.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == NativeAudioFormat.sampleRate,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
              (1...2).contains(format.mChannelsPerFrame) else { unsupportedBuffers += 1; return }
        let frames = sampleBuffer.numSamples, channels = Int(format.mChannelsPerFrame)
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let appended: Bool? = try? sampleBuffer.withAudioBufferList { list, _ -> Bool in
            let buffers = planar ? channels : 1
            let needed = frames * 4 * (planar ? 1 : channels)
            guard frames > 0, list.count >= buffers,
                  (0..<buffers).allSatisfy({ list[$0].mData != nil && Int(list[$0].mDataByteSize) >= needed }) else { return false }
            let first = list[0].mData!.assumingMemoryBound(to: Float.self)
            pending.reserveCapacity(pending.count + frames * 2)
            if planar {
                let second = channels == 2 ? list[1].mData!.assumingMemoryBound(to: Float.self) : first
                for index in 0..<frames { pending.append(first[index]); pending.append(second[index]) }
            } else {
                for index in 0..<frames {
                    let left = first[index * channels]
                    pending.append(left); pending.append(channels == 2 ? first[index * 2 + 1] : left)
                }
            }
            return true
        }
        guard appended == true else { unsupportedBuffers += 1; return }
        drain()
    }

    /// Interleaved stereo at 48 kHz, as from `append(_:)`.
    func append(interleaved samples: [Float]) {
        pending.append(contentsOf: samples.prefix(samples.count / 2 * 2))
        drain()
    }

    private func drain() {
        let excess = pending.count / 2 - Self.maxPendingFrames
        if excess > 0 { pending.removeFirst(excess * 2); droppedFrames += excess }
        let packetSamples = NativeAudioFormat.packetFrames * 2
        var offset = 0
        while pending.count - offset >= packetSamples {
            if let packet = encodePacket(at: offset) { onPacket?(packet) }
            offset += packetSamples
        }
        pending.removeFirst(offset)
    }

    private func encodePacket(at offset: Int) -> Data? {
        pending.withUnsafeMutableBufferPointer { samples -> Data? in
            output.withUnsafeMutableBytes { out -> Data? in
                guard let base = samples.baseAddress, let destination = out.baseAddress else { return nil }
                var input = NativeConverterInput(data: UnsafeMutableRawPointer(base + offset),
                                                 bytes: UInt32(NativeAudioFormat.packetFrames * 8),
                                                 packets: UInt32(NativeAudioFormat.packetFrames), description: nil)
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(out.count),
                                                                                  mData: destination))
                var packets: UInt32 = 1
                var description = AudioStreamPacketDescription()
                let status = AudioConverterFillComplexBuffer(converter, nativeConverterInput, &input, &packets, &list, &description)
                let start = Int(description.mStartOffset), length = Int(description.mDataByteSize)
                guard status == noErr || status == nativeNoMoreInput, packets == 1, length > 0, start >= 0,
                      start + length <= out.count else { return nil }
                return Data(bytes: destination + start, count: length)
            }
        }
    }
}

/// Decodes Opus packets to interleaved 48 kHz stereo. Use from one queue at a time.
final class NativeAudioDecoder {
    private let converter: AudioConverterRef
    private let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    private var input = [UInt8](repeating: 0, count: Int(ML_AUDIO_MAX_PAYLOAD))
    private var output = [Float](repeating: 0, count: NativeAudioFormat.maxPacketFrames * 2)

    init() throws {
        var opus = NativeAudioFormat.opus, pcm = NativeAudioFormat.pcm
        var created: AudioConverterRef?
        guard AudioConverterNew(&opus, &pcm, &created) == noErr, let converter = created else {
            description.deallocate()
            throw NativeMediaError("This Mac cannot decode Opus sound.")
        }
        self.converter = converter
    }
    deinit { AudioConverterDispose(converter); description.deallocate() }

    /// Decodes one packet and passes its samples to `consume` before returning;
    /// returns the frames decoded, 0 for a packet it could not decode.
    @discardableResult
    func decode(_ packet: Data, consume: (UnsafeBufferPointer<Float>) -> Void) -> Int {
        guard !packet.isEmpty, packet.count <= input.count else { return 0 }
        input.withUnsafeMutableBytes { _ = packet.copyBytes(to: $0) }
        description.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        let frames = input.withUnsafeMutableBytes { source -> Int in
            output.withUnsafeMutableBytes { out -> Int in
                guard let data = source.baseAddress, let destination = out.baseAddress else { return 0 }
                var feed = NativeConverterInput(data: data, bytes: UInt32(packet.count), packets: 1, description: description)
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(out.count),
                                                                                  mData: destination))
                var frames = UInt32(NativeAudioFormat.maxPacketFrames)
                let status = AudioConverterFillComplexBuffer(converter, nativeConverterInput, &feed, &frames, &list, nil)
                guard status == noErr || status == nativeNoMoreInput else { return 0 }
                return min(Int(frames), NativeAudioFormat.maxPacketFrames)
            }
        }
        if frames > 0 { output.withUnsafeBufferPointer { consume(UnsafeBufferPointer(rebasing: $0[..<(frames * 2)])) } }
        return frames
    }
}

/// Decoded sound waiting to play: at most half a second of interleaved stereo.
/// The decode queue writes and the audio render thread reads, each briefly
/// under an unfair lock. Rust's playout rule decides when playback starts and
/// how much old sound to drop.
final class NativeAudioBuffer: @unchecked Sendable {
    static let capacityFrames = 24_000
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private let samples = UnsafeMutablePointer<Float>.allocate(capacity: NativeAudioBuffer.capacityFrames * 2)
    private var start = 0
    private var count = 0
    private var playing = false
    private var underruns = 0
    private var droppedFrames = 0

    init() {
        lock.initialize(to: os_unfair_lock())
        samples.initialize(repeating: 0, count: Self.capacityFrames * 2)
    }
    deinit {
        lock.deinitialize(count: 1); lock.deallocate()
        samples.deallocate()
    }

    func write(_ interleaved: UnsafeBufferPointer<Float>) {
        let frames = min(interleaved.count / 2, Self.capacityFrames)
        guard frames > 0, let source = interleaved.baseAddress else { return }
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let overflow = count + frames - Self.capacityFrames
        if overflow > 0 { discardLocked(overflow) }
        var written = 0
        while written < frames {
            let end = (start + count) % Self.capacityFrames
            let run = min(frames - written, Self.capacityFrames - end)
            (samples + end * 2).update(from: source + written * 2, count: run * 2)
            count += run; written += run
        }
        var play: UInt8 = 0, drop: UInt32 = 0
        guard ml_audio_playout(UInt32(count), playing ? 1 : 0, &play, &drop) == ML_SESSION_OK else { return }
        playing = play != 0
        if drop > 0 { discardLocked(min(count, Int(drop))) }
    }

    private func discardLocked(_ frames: Int) {
        start = (start + frames) % Self.capacityFrames; count -= frames; droppedFrames += frames
    }

    /// Fills the render buffers, deinterleaving into two buffers or copying
    /// into one interleaved buffer. Returns false when it wrote silence only.
    /// Running dry pauses playback until the playout rule starts it again.
    func read(into list: UnsafeMutableAudioBufferListPointer, frames: Int) -> Bool {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let available = playing ? min(count, frames) : 0
        let planar = list.count >= 2
        let outputs = planar ? 2 : 1, stride = planar ? 1 : 2
        for channel in 0..<outputs {
            guard let data = list[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let capacity = Int(list[channel].mDataByteSize) / 4 / stride
            let copied = min(available, capacity)
            for frame in 0..<copied {
                let index = ((start + frame) % Self.capacityFrames) * 2
                if planar { data[frame] = samples[index + channel] }
                else { data[frame * 2] = samples[index]; data[frame * 2 + 1] = samples[index + 1] }
            }
            if capacity > copied { (data + copied * stride).update(repeating: 0, count: (capacity - copied) * stride) }
        }
        if playing {
            start = (start + available) % Self.capacityFrames; count -= available
            if available < frames { playing = false; underruns += 1 }
        }
        return available > 0
    }

    func reset() {
        os_unfair_lock_lock(lock); start = 0; count = 0; playing = false; os_unfair_lock_unlock(lock)
    }
    /// Frames buffered, times playback ran dry, and frames dropped.
    func snapshot() -> (buffered: Int, underruns: Int, droppedFrames: Int) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return (count, underruns, droppedFrames)
    }
}

struct NativeAudioStats: Equatable {
    var packets = 0
    /// Packets the sharing Mac numbered but never sent, as when its queue was full.
    var gaps = 0
    /// Packets dropped here because too many were waiting to decode.
    var droppedPackets = 0
    var undecodable = 0
    var underruns = 0
    var droppedFrames = 0
    var bufferedFrames = 0
}

/// Plays the sharing Mac's sound through AVAudioEngine. Packets arrive from
/// the receive thread and decode on a serial queue, at most 32 waiting. The
/// engine starts on the first packet and, after a device change stops it,
/// restarts at most once a second.
final class NativeAudioPlayer: @unchecked Sendable {
    static let maxWaiting = 32
    private let queue = DispatchQueue(label: "MacLink.native.audio", qos: .userInteractive)
    private let buffer = NativeAudioBuffer()
    private let lock = NSLock()
    private var waiting = 0
    private var muted: Bool
    private var stopped = false
    private var stats = NativeAudioStats()
    // Queue-only state.
    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var decoder: NativeAudioDecoder?
    private var lastSequence: UInt32?
    private var lastStart = -Double.infinity
    private var reportedStartFailure = false

    init(muted: Bool) { self.muted = muted }

    func receive(_ packet: NativeAudioPacket) {
        lock.lock()
        guard !stopped, !muted else { lock.unlock(); return }
        stats.packets += 1
        guard waiting < Self.maxWaiting else { stats.droppedPackets += 1; lock.unlock(); return }
        waiting += 1
        lock.unlock()
        queue.async { [self] in
            lock.lock(); waiting -= 1; let active = !stopped && !muted; lock.unlock()
            if active { play(packet) }
        }
    }

    private func play(_ packet: NativeAudioPacket) {
        if let last = lastSequence, packet.sequence != last &+ 1 {
            lock.lock(); stats.gaps += Int(packet.sequence &- last &- 1); lock.unlock()
        }
        lastSequence = packet.sequence
        if decoder == nil { decoder = try? NativeAudioDecoder() }
        let decoded = decoder?.decode(packet.payload) { buffer.write($0) } ?? 0
        if decoded == 0 { lock.lock(); stats.undecodable += 1; lock.unlock() }
        startEngineIfNeeded()
    }

    private func startEngineIfNeeded() {
        if let engine, engine.isRunning { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStart >= 1 else { return }
        lastStart = now
        if engine == nil { engine = makeEngine() }
        do {
            try engine?.start()
        } catch {
            // Build a fresh engine next time.
            releaseEngine()
            if !reportedStartFailure {
                reportedStartFailure = true
                nativeAudioLog.error("sound from the sharing Mac could not play: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func makeEngine() -> AVAudioEngine? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: NativeAudioFormat.sampleRate, channels: 2) else { return nil }
        let engine = AVAudioEngine(), buffer = self.buffer
        let source = AVAudioSourceNode(format: format) { silence, _, frames, list in
            if !buffer.read(into: UnsafeMutableAudioBufferListPointer(list), frames: Int(frames)) { silence.pointee = true }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        // A new output device or format stops the engine; the next packet
        // builds a fresh one for it.
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: nil) { [weak self, weak engine] _ in
            self?.queue.async { [weak self] in
                // A packet may already have restarted it on the new device.
                guard let self, let engine, self.engine === engine, !engine.isRunning else { return }
                self.releaseEngine()
            }
        }
        return engine
    }

    private func releaseEngine() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        engine?.stop(); engine = nil
    }

    /// Muting stops playback at once and discards sound until unmuted.
    func setMuted(_ value: Bool) {
        lock.lock(); let changed = muted != value; muted = value; lock.unlock()
        guard changed, value else { return }
        queue.async { [self] in silence() }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        queue.async { [self] in silence() }
    }

    private func silence() {
        releaseEngine(); decoder = nil; lastSequence = nil
        buffer.reset()
    }

    func snapshot() -> NativeAudioStats {
        let buffered = buffer.snapshot()
        lock.lock(); var result = stats; lock.unlock()
        result.underruns = buffered.underruns; result.droppedFrames = buffered.droppedFrames
        result.bufferedFrames = buffered.buffered
        return result
    }
}

/// Host: numbers packets, and bounds those waiting to be written to 8 (80 ms).
/// Newer sound is dropped rather than queued behind a stalled connection;
/// dropped packets still use a number, so the viewer sees the gap.
final class NativeAudioSendGate: @unchecked Sendable {
    static let maxWaiting = 8
    private let lock = NSLock()
    private var sequence: UInt32 = 0
    private var waiting = 0

    /// The packet's number, or nil to drop it.
    func admit() -> UInt32? {
        lock.lock(); defer { lock.unlock() }
        let number = sequence
        sequence &+= 1
        guard waiting < Self.maxWaiting else { return nil }
        waiting += 1
        return number
    }
    func finished() {
        lock.lock(); waiting = max(0, waiting - 1); lock.unlock()
    }
}

enum NativeAudioSupport {
    /// Encodes and decodes 200 ms of a tone through AudioToolbox's Opus codec;
    /// true when every packet encodes and the sound comes back.
    static func probeOpus() -> Bool {
        guard let encoder = try? NativeAudioEncoder(), let decoder = try? NativeAudioDecoder() else { return false }
        var packets: [Data] = []
        encoder.onPacket = { packets.append($0) }
        let frames = 9_600
        var tone = [Float](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            let value = Float(sin(2 * Double.pi * 440 * Double(index) / NativeAudioFormat.sampleRate)) * 0.25
            tone[index * 2] = value; tone[index * 2 + 1] = value
        }
        // 10 ms at a time, as capture delivers it; at once, the pending bound would trim it.
        let step = NativeAudioFormat.packetFrames * 2
        for start in stride(from: 0, to: tone.count, by: step) { encoder.append(interleaved: Array(tone[start..<(start + step)])) }
        guard packets.count == frames / NativeAudioFormat.packetFrames else { return false }
        var energy: Float = 0, decoded = 0
        for packet in packets { decoded += decoder.decode(packet) { for sample in $0 { energy += sample * sample } } }
        return decoded >= frames / 2 && energy > 1
    }
}
