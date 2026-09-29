// Manual check of the viewer-sized display on this Mac (it changes the
// display arrangement for about ten seconds, so it is not part of CI and must
// not run during a session): a request becomes the main display in its exact
// Retina mode, resizes in place, and releasing it restores the original.
import AppKit

@main
enum VirtualDisplayCheck {
    static func main() {
        let original = CGMainDisplayID(), originalBounds = CGDisplayBounds(original)
        let shared = NativeSharedDisplay()
        var failures: [String] = []
        func pump(_ seconds: Double) { RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds)) }
        func check(_ width: Int, _ height: Int, _ scale: Int) {
            var result: Bool?
            shared.apply(width: width, height: height, scale: scale) { result = $0 }
            let deadline = Date(timeIntervalSinceNow: 5)
            while result == nil && Date() < deadline { pump(0.1) }
            pump(1)
            let main = CGMainDisplayID(), bounds = CGDisplayBounds(main), mode = CGDisplayCopyDisplayMode(main)
            let line = "request \(width)×\(height)@\(scale)x: applied \(result.map(String.init) ?? "timeout"); main \(main) " +
                "bounds \(Int(bounds.width))×\(Int(bounds.height)), pixels \(mode?.pixelWidth ?? 0)×\(mode?.pixelHeight ?? 0)"
            print(line)
            if result != true || Int(bounds.width) != width || Int(bounds.height) != height
                || mode?.pixelWidth != width * scale || mode?.pixelHeight != height * scale { failures.append(line) }
        }
        print("available:", NativeSharedDisplay.isAvailable, "original main", original, originalBounds)
        check(1512, 916, 2)
        check(1280, 800, 2)
        shared.release()
        pump(3)
        let restored = CGDisplayBounds(CGMainDisplayID())
        print("after release: main \(CGMainDisplayID()) bounds \(Int(restored.width))×\(Int(restored.height))")
        if restored.size != originalBounds.size { failures.append("original display size not restored") }
        if failures.isEmpty { print("Virtual display check passed.") } else { print("FAILED:", failures); exit(1) }
    }
}
