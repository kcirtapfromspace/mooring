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
        window.title = "MacLink presentation measurement"
        window.level = .floating
        let view = NativeVideoView(frame: window.contentView!.bounds, device: MTLCreateSystemDefaultDevice())
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        view.geometry = NativeDisplayGeometry(x: 0, y: 0, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080)
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
        let runs: [(size: CGSize?, paired: Bool)] = [(window1080, false), (retina, false), (window1080, true), (retina, true)]
        func run(_ index: Int) {
            guard index < runs.count else {
                let data = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self)); exit(0)
            }
            let paired = runs[index].paired
            if let size = runs[index].size { view.autoResizeDrawable = false; view.drawableSize = size }
            else { view.autoResizeDrawable = true }
            var presented = 0
            view.onPresented = { presented += 1 }
            _ = view.takeDrawStats()
            let seconds = 5.0, total = Int(seconds * 60)
            let feeder = DispatchQueue(label: "feeder", qos: .userInteractive)
            let began = ProcessInfo.processInfo.systemUptime
            // Warm up, then count only the measured span.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                presented = 0
                let start = ProcessInfo.processInfo.systemUptime
                feeder.async {
                    for frameIndex in 0..<total {
                        // Paired: two frames 1 ms apart every 1/30 s, still 60 per second.
                        let due = paired ? start + Double(frameIndex / 2) / 30 + Double(frameIndex % 2) * 0.001
                                         : start + Double(frameIndex) / 60
                        let wait = due - ProcessInfo.processInfo.systemUptime
                        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                        if let buffer = frame(frameIndex, pool: pool) { view.display(buffer) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let elapsed = ProcessInfo.processInfo.systemUptime - start
                        let draw = view.takeDrawStats()
                        results.append(["drawable": "\(Int(view.drawableSize.width))x\(Int(view.drawableSize.height))",
                                        "drawing": draw.summary,
                                        "arrival": paired ? "paired" : "even",
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
