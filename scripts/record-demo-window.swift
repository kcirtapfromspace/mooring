// Build locally: swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos14.0
//   scripts/record-demo-window.swift -o /tmp/mooring-record-window
// This records exactly one explicitly selected Mooring window, never a display.
import AppKit
import AVFoundation
import ScreenCaptureKit
import Darwin

struct RecordingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class WindowWriter: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "MooringDemoRecording")
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    private var started = false
    private var streamFailed = false
    private var frames = 0
    private var lastSample: CMSampleBuffer?
    private var completeSamples = 0
    private var blockedSamples = 0
    private var otherSamples = 0

    init(output: URL) throws {
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1440, AVVideoHeightKey: 900,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        super.init()
        guard writer.canAdd(input) else { throw RecordingError(message: "Cannot create H.264 recording.") }
        writer.add(input)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int else { return }
        guard status == SCFrameStatus.complete.rawValue else { otherSamples += 1; return }
        completeSamples += 1
        lastSample = buffer
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
            started = true
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { blockedSamples += 1; return }
        if input.append(buffer) { frames += 1 }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.streamFailed = true }
    }

    func finish() async throws {
        let result = queue.sync { () -> (Int, Bool) in
            if started {
                let end = CMClockGetTime(CMClockGetHostTimeClock())
                if let lastSample, input.isReadyForMoreMediaData {
                    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: end, decodeTimeStamp: .invalid)
                    var tail: CMSampleBuffer?
                    if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lastSample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &tail) == noErr, let tail {
                        _ = input.append(tail)
                    }
                }
                writer.endSession(atSourceTime: end)
                input.markAsFinished()
            }
            print("Capture samples: \(completeSamples) complete, \(otherSamples) idle/other, \(blockedSamples) encoder drops.")
            return (frames, streamFailed)
        }
        guard result.0 > 0 else {
            writer.cancelWriting()
            throw RecordingError(message: "No complete window frames arrived. No recording is ready for use.")
        }
        await writer.finishWriting()
        guard writer.status == .completed, !result.1 else {
            throw RecordingError(message: "Window capture ended unexpectedly. Discard this take.")
        }
    }
}

@main @MainActor struct RecordMooringWindow {
    static let allowedBundleIDs: Set<String> = ["dev.maclink.launcher"]

    static func main() async {
        do { try await run() }
        catch {
            fputs("Mooring demo: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        umask(0o077)
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["check"] || arguments == ["request-access"] || arguments == ["list"] || (arguments.count == 4 && arguments[0] == "record") else {
            throw RecordingError(message: "Usage: mooring-record-window check | request-access | list | record WINDOW_ID SECONDS OUTPUT.mp4")
        }
        if arguments == ["request-access"] {
            let available = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
            print(available ? "Screen Recording access is available. No capture started." : "macOS recording permission was requested. Complete it in System Settings, then relaunch this session. No capture started.")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw RecordingError(message: "Screen Recording access is not granted to this recording process. No capture was started; enable access for its terminal/app in System Settings, then relaunch it.")
        }
        if arguments == ["check"] { print("Screen Recording access is available. No capture started."); return }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            allowedBundleIDs.contains($0.owningApplication?.bundleIdentifier ?? "") && $0.windowLayer == 0 && $0.frame.width > 100 && $0.frame.height > 100
        }
        if arguments == ["list"] {
            for window in windows {
                print("Mooring window ID \(window.windowID) · \(Int(window.frame.width))×\(Int(window.frame.height)) points")
            }
            if windows.isEmpty { print("No eligible Mooring window is visible.") }
            return
        }
        guard let id = UInt32(arguments[1]), let window = windows.first(where: { $0.windowID == id }),
              let seconds = Int(arguments[2]), (1...60).contains(seconds) else {
            throw RecordingError(message: "Choose one currently visible Mooring window ID and a duration from 1 to 60 seconds.")
        }
        let output = URL(fileURLWithPath: arguments[3]).standardizedFileURL.resolvingSymlinksInPath()
        guard output.pathExtension.lowercased() == "mp4", !FileManager.default.fileExists(atPath: output.path) else {
            throw RecordingError(message: "Use a new .mp4 output path; existing files are never overwritten.")
        }
        guard !output.pathComponents.contains("site"), !output.pathComponents.contains(".git") else {
            throw RecordingError(message: "Keep raw takes outside the website and Git. Publish only an edited, privacy-reviewed output.")
        }
        var parent = output.deletingLastPathComponent()
        while parent.path != "/" {
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path) {
                throw RecordingError(message: "Raw takes must be stored outside every Git checkout.")
            }
            parent.deleteLastPathComponent()
        }
        let sink = try WindowWriter(output: output)
        let configuration = SCStreamConfiguration()
        configuration.width = 1440
        configuration.height = 900
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.capturesAudio = false
        configuration.showsCursor = true
        configuration.preservesAspectRatio = true
        configuration.scalesToFit = true
        let background = CGColor(red: 36 / 255, green: 39 / 255, blue: 38 / 255, alpha: 1)
        configuration.backgroundColor = background
        defer { withExtendedLifetime(background) {} }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        print("Recording the selected Mooring window for \(seconds) seconds. No audio or other windows are included.")
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        try await stream.stopCapture()
        try await sink.finish()
        print("Saved a LOCAL, UNREVIEWED take. Review all frames before editing or publication.")
    }
}
