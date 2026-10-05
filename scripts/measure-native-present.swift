// Presentation throughput of the viewer's NativeVideoView, measured on screen.
// Synthetic 1920x1080 frames tagged like hardware-decoder output arrive at an
// average 60 Hz from a background queue, as decoded frames do: evenly, and in
// pairs as Wi-Fi delivers them after a stall. The report counts frames the
// display actually presented. Opens one small window for a few seconds;
// no capture, network, Keychain or permission is involved.
import AppKit
import CoreVideo
import Metal

@main
enum NativePresentMeasurement {
    static func frame(_ index: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer), height = CVPixelBufferGetHeight(buffer)
        memset(base, Int32(40 + index % 60), row * height)
        let bar = (index * 24) % max(1, row - 96)
        for y in 0..<height { memset(base + y * row + bar, 230, 96) } // a moving vertical bar
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for (key, value) in [(kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                             (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
                             (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2)] {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
        return buffer
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Mooring presentation measurement"
        window.level = .floating
        let view = NativeVideoView(frame: window.contentView!.bounds, device: MTLCreateSystemDefaultDevice())
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        view.geometry = NativeDisplayGeometry(x: 0, y: 0, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080)
        // MOORING_PRESENT_NO_SYNC=1 measures Lower Display Latency.
        view.waitsForDisplayRefresh = ProcessInfo.processInfo.environment["MOORING_PRESENT_NO_SYNC"] != "1"
        window.orderFrontRegardless()

        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 8] as CFDictionary, attributes as CFDictionary, &pool)
        guard let pool else { fputs("No pixel buffer pool\n", stderr); exit(1) }

        var results: [[String: Any]] = []
        // Drawable sizes: this Mac's window as is, then a Retina full-screen viewer's.
        let retina = CGSize(width: 3456, height: 2234)
        let window1080 = CGSize(width: 1600, height: 900)
        // Arrival: even 60 fps, pairs 1 ms apart, or sparse (4 a second, like
        // typing), which measures the wait from decoded to shown.
        let runs: [(size: CGSize?, arrival: String)] = [(window1080, "even"), (retina, "even"), (window1080, "paired"), (retina, "paired"),
                                                          (retina, "sparse")]
        func run(_ index: Int) {
            guard index < runs.count else {
                let data = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self)); exit(0)
            }
            let arrival = runs[index].arrival, paired = arrival == "paired", sparse = arrival == "sparse"
            if let size = runs[index].size { view.autoResizeDrawable = false; view.drawableSize = size }
            else { view.autoResizeDrawable = true }
            var presented = 0, waits: [Double] = []
            view.onPresented = { presented += 1 }
            // A virtual display gives no present time; then the handler's own
            // time, just after presentation, stands in for it.
            view.onFrameTiming = { timing in
                let shown = timing.presentedUs > 0 ? timing.presentedUs : NativeClock.nowUs
                waits.append(Double(shown - timing.decodedUs) / 1000)
            }
            _ = view.takeDrawStats()
            let seconds = 5.0, total = sparse ? 20 : Int(seconds * 60)
            let feeder = DispatchQueue(label: "feeder", qos: .userInteractive)
            let began = ProcessInfo.processInfo.systemUptime
            // Warm up, then count only the measured span.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                presented = 0; waits = []
                let start = ProcessInfo.processInfo.systemUptime
                feeder.async {
                    for frameIndex in 0..<total {
                        // Paired: two frames 1 ms apart every 1/30 s, still 60 per second.
                        // Sparse frames land at random points within a refresh.
                        let due = paired ? start + Double(frameIndex / 2) / 30 + Double(frameIndex % 2) * 0.001
                                         : sparse ? start + Double(frameIndex) * 0.25 + Double.random(in: 0..<0.0167)
                                         : start + Double(frameIndex) / 60
                        let wait = due - ProcessInfo.processInfo.systemUptime
                        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                        if let buffer = frame(frameIndex, pool: pool) {
                            let now = NativeClock.nowUs
                            NativeFrameTiming.attach(buffer, hostUs: now, decodeStartUs: now, decodedUs: now)
                            view.display(buffer)
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let elapsed = ProcessInfo.processInfo.systemUptime - start
                        let draw = view.takeDrawStats()
                        results.append(["drawable": "\(Int(view.drawableSize.width))x\(Int(view.drawableSize.height))",
                                        "drawing": draw.summary,
                                        "arrival": arrival,
                                        "decoded_to_shown_ms_median": NativeLatencyWindow.percentile(waits, 0.5) ?? -1,
                                        "decoded_to_shown_ms_p95": NativeLatencyWindow.percentile(waits, 0.95) ?? -1,
                                        "offered_fps": Double(total) / seconds, "presented_fps": Double(presented) / seconds, "elapsed_s": elapsed,
                                        "setup_s": start - began])
                        run(index + 1)
                    }
                }
            }
        }
        run(0)
        app.run()
    }
}
