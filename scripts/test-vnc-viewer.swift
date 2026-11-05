import AppKit
import IOSurface

// Drives the real VNCView and ml_vnc_* against scripts/fake-vnc-server.py on
// loopback: pixels and their orientation in memory, the double-buffer
// catch-up, window-to-desktop pointer mapping, and the key and button events
// the server receives, including releases when the session closes.

func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
           color: NSColor = .labelColor) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    view.font = .systemFont(ofSize: size, weight: weight)
    view.textColor = color
    return view
}

func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation = .vertical,
           spacing: CGFloat = 12) -> NSStackView {
    let view = NSStackView(views: views)
    view.orientation = orientation
    view.spacing = spacing
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
        exit(1)
    }
}

func pixel(_ surface: IOSurface, _ x: Int, _ y: Int) -> [UInt8] {
    surface.lock(options: .readOnly, seed: nil)
    defer { surface.unlock(options: .readOnly, seed: nil) }
    let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self) + y * surface.bytesPerRow + x * 4
    return Array(UnsafeBufferPointer(start: base, count: 4))
}

func until(_ seconds: Double, _ step: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if step() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return false
}

@main
struct VNCViewerTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("mooring-vnc-viewer-\(getpid()).json")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-I", root.appendingPathComponent("scripts/fake-vnc-server.py").path, record.path]
        let output = Pipe()
        server.standardOutput = output
        try server.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        guard let port = UInt16(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            check(false, "server port: \(line)"); return
        }

        var id: UInt64 = 0
        var nothing: [UInt8] = []
        let opened = "viewer-test".withCString { key in "".withCString { user in ml_vnc_open(key, port, user, &nothing, 0, &id) } }
        check(opened == 0 && id != 0, "open: \(opened)")

        let view = VNCView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.sessionID = id
        var events: [String] = []
        var buffer = [CChar](repeating: 0, count: Int(ML_VNC_EVENT_CAPACITY))
        func poll() {
            var length = 0
            while ml_vnc_poll_event(id, &buffer, buffer.count, &length) == 0, length > 0 {
                let event = try? JSONSerialization.jsonObject(with: Data(bytes: buffer, count: length)) as? [String: Any]
                events.append(event?["event"] as? String ?? "?")
            }
        }
        check(until(10) { poll(); return events.contains("connected") }, "connected: \(events)")

        // First picture: top row red, bottom row blue, the padding made opaque.
        var first: IOSurface?
        check(until(5) {
            view.refresh()
            guard let shown = view.layer?.contents as? IOSurface, pixel(shown, 0, 3) == [200, 0, 0, 255] else { return false }
            first = shown
            return true
        }, "first picture")
        let shown = first!
        check(shown.width == 8 && shown.height == 4, "surface size \(shown.width)x\(shown.height)")
        check(pixel(shown, 7, 0) == [0, 0, 200, 255], "top row red: \(pixel(shown, 7, 0))")
        check(pixel(shown, 3, 2) == [0, 0, 0, 255], "middle black: \(pixel(shown, 3, 2))")

        // Pointer: the 80x40 view shows the 8x4 desktop at 10x, so window point
        // (15, 35) (origin bottom-left) is desktop pixel (1, 0). The server
        // answers the first pointer event with the second update.
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseMoved(with: mouse(.mouseMoved, NSPoint(x: 15, y: 35)))
        // The second update goes to the other surface, which first catches up
        // on the first picture: both changes are visible in the new front.
        check(until(5) {
            view.refresh()
            guard let now = view.layer?.contents as? IOSurface, now !== shown else { return false }
            return pixel(now, 1, 1) == [0, 200, 0, 255]
        }, "second update shown in the other surface")
        let second = view.layer?.contents as! IOSurface
        check(pixel(second, 0, 0) == [0, 0, 200, 255] && pixel(second, 0, 3) == [200, 0, 0, 255], "back surface caught up")
        check(pixel(shown, 1, 1) == [0, 0, 0, 255], "the shown surface was not written while shown")
        view.mouseMoved(with: mouse(.mouseMoved, NSPoint(x: 79, y: 1)))

        // A view showing only some rows, as the main view and the camera row
        // do: what it draws, and where its pointer lands.
        func center(_ view: VNCView) -> [UInt8] {
            let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let layer = view.layer!
            let frame = layer.frame
            layer.frame = CGRect(x: 0, y: 0, width: 4, height: 4)
            layer.render(in: context)
            layer.frame = frame
            let data = context.data!.assumingMemoryBound(to: UInt8.self)
            return [data[2 * 16 + 8], data[2 * 16 + 9], data[2 * 16 + 10]]
        }
        // Colour management and smoothing shift the values a little; which
        // colour dominates is what shows the right rows are drawn.
        func isRed(_ c: [UInt8]) -> Bool { c[0] > 150 && c[2] < 60 }
        func isBlue(_ c: [UInt8]) -> Bool { c[2] > 150 && c[0] < 60 }
        view.region = (0, 1)
        check(isRed(center(view)), "top row alone is red: \(center(view))")
        view.region = (3, 1)
        check(isBlue(center(view)), "bottom row alone is blue: \(center(view))")
        view.mouseMoved(with: mouse(.mouseMoved, NSPoint(x: 15, y: 20)))
        let mirror = VNCView(frame: NSRect(x: 0, y: 0, width: 80, height: 10))
        mirror.source = view
        mirror.region = (0, 1)
        view.mirror = mirror
        view.region = nil
        func key(_ type: NSEvent.EventType, _ code: UInt16, _ text: String, _ flags: UInt = 0) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags), timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: text,
                             charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        view.keyDown(with: key(.keyDown, 0x00, "a"))
        view.keyUp(with: key(.keyUp, 0x00, "a"))
        // Left Shift down (device bit 0x02), then held when the session closes.
        view.flagsChanged(with: key(.flagsChanged, 0x38, "", NSEvent.ModifierFlags.shift.rawValue | 0x02))
        view.keyDown(with: key(.keyDown, 0x24, "\r"))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check(ml_vnc_close(id) == 0, "close")
        server.waitUntilExit()

        let data = try Data(contentsOf: record)
        try? FileManager.default.removeItem(at: record)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let keys = (result["keys"] as! [[Int]]).map { ($0[0], $0[1]) }
        let pointer = (result["pointer"] as! [[Int]])
        check(result["error"] == nil, "server error: \(result["error"] ?? "")")
        check((result["encodings"] as! [Int]).first == 16, "ZRLE preferred: \(result["encodings"]!)")
        check(pointer.first == [0, 1, 0], "pointer mapped to (1, 0): \(pointer)")
        check(pointer.contains([0, 7, 3]), "pointer at the far corner: \(pointer)")
        check(pointer.contains([0, 1, 3]), "pointer in a view of the bottom row lands on row 3: \(pointer)")
        let expected: [(Int, Int)] = [(1, 0x61), (0, 0x61), (1, 0xffe1), (1, 0xff0d)]
        check(Array(keys.prefix(4)).elementsEqual(expected, by: ==), "keys sent: \(keys)")
        let released = Set(keys.dropFirst(4).filter { $0.0 == 0 }.map { $0.1 })
        check(released == [0xffe1, 0xff0d], "held Shift and Return released on close: \(keys)")
        print("VNC viewer: \(events.count) events, opaque BGRA in two surfaces with catch-up, pointer mapping, keys and releases on close passed.")
    }
}
