// Maps where macOS places a new status item for a range of "NSStatusItem
// Preferred Position" values, using the same item setup as Mooring's camera
// gap (app/NativeMenuBarGap.swift). Run on a sharing Mac whose gap lands in
// the wrong place, with no Mooring gap in place (leave full screen first):
//
//   swiftc -O -parse-as-library scripts/probe-menu-bar-order.swift -o /tmp/probe-menu-bar-order
//   /tmp/probe-menu-bar-order
//
// Each line is one trial item: its position value and where it landed, in
// points from the main display's left edge. Its icons shuffle for about 15
// seconds; nothing is clicked, read from other apps or saved afterwards.
import AppKit

final class Probe: NSObject, NSApplicationDelegate {
    private static let name = "MooringOrderProbe"
    private static let key = "NSStatusItem Preferred Position \(name)"
    private var positions: [Double?] = [nil, 50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1200, 1500, 2000,
                                        3000, 5000, 10_000, 16_384, 100_000, 10_000_000]
    private let screen = NSScreen.screens[0].frame

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("main display \(Int(screen.width))×\(Int(screen.height)) points, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        next()
    }
    private func next() {
        guard !positions.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.key)
            exit(0)
        }
        let position = positions.removeFirst()
        if let position { UserDefaults.standard.set(position, forKey: Self.key) }
        else { UserDefaults.standard.removeObject(forKey: Self.key) }
        let item = NSStatusBar.system.statusItem(withLength: 1)
        item.autosaveName = Self.name
        item.behavior = []
        item.button?.isEnabled = false
        item.button?.setAccessibilityElement(false)
        settle(item, previous: nil, reads: 0) { frame in
            let label = position.map { String(format: "%10.0f", $0) } ?? "      none"
            print("position \(label) -> x \(Int(frame.minX))...\(Int(frame.maxX)), \(Int(self.screen.maxX - frame.maxX)) from the right")
            NSStatusBar.system.removeStatusItem(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.next() }
        }
    }
    /// Read every 0.15 s until two readings agree: new items slide into place.
    private func settle(_ item: NSStatusItem, previous: NSRect?, reads: Int, then: @escaping (NSRect) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let frame = item.button?.window?.frame ?? .zero
            if frame == previous || reads >= 6 { then(frame) }
            else { self.settle(item, previous: frame, reads: reads + 1, then: then) }
        }
    }
}

@main enum ProbeMenuBarOrder {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let probe = Probe()
        app.delegate = probe
        app.run()
    }
}
