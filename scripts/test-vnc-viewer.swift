import AppKit
import IOSurface

// Drives the real VNCView and ml_vnc_* against scripts/fake-vnc-server.py on
// loopback: pixels and their orientation in memory, the double-buffer
// catch-up, window-to-desktop pointer mapping, and the key and button events
// the server receives, including releases when the session closes. Then the
// viewer window: its footer in a window and in full screen, and ⌃⌘D.

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

        // The viewer window's footer, as in Mac-to-Mac viewing: below the
        // picture in a window and in full screen, with Exit Full Screen there,
        // and ⌃⌘D through the responder chain. The window's picture takes the
        // desktop's 8x4 size from the session view above, as the camera row's
        // view does; with no session of its own it never polls or draws. Full
        // screen is driven through the delegate calls AppKit makes, at the size
        // AppKit gives it on a 14-inch MacBook Pro: 1800x1130, below the housing.
        let viewer = VNCViewerWindow(name: "Footer test", connectionID: "footer-test", sessionID: 0)
        viewer.view.source = view
        let viewerWindow = viewer.window!
        let content = viewerWindow.contentView!
        let footer = viewer.footer
        var footerChanges: [Bool] = []
        viewer.onDiagnosticBarChange = { footerChanges.append($0) }
        func note(_ name: Notification.Name) -> Notification { Notification(name: name, object: viewerWindow) }
        func checkFooter(shown: Bool, _ context: String) {
            content.layoutSubtreeIfNeeded()
            let size = content.bounds.size
            let bar = footer.bar.convert(footer.bar.bounds, to: content), picture = viewer.view.frame
            if shown {
                check(!footer.bar.isHidden && bar == CGRect(x: 12, y: 6, width: size.width - 24, height: 22), "\(context): footer bar at \(bar) in \(size)")
                check(picture == CGRect(x: 0, y: 34, width: size.width, height: size.height - 34), "\(context): picture above the footer: \(picture)")
            } else {
                check(footer.bar.isHidden, "\(context): footer hidden")
                check(picture == CGRect(origin: .zero, size: size), "\(context): picture fills the window: \(picture)")
            }
        }
        let items = footer.bar.arrangedSubviews
        check(footer.bar.superview === content && items.count == 6 && items[0] is NSImageView && items[1] === footer.status
              && items[3] === footer.allowSystemKeys && items[4] === footer.exitFullScreen && items[5] === footer.hide,
              "footer on the window background: mark, status, Allow ⌘-Tab…, Exit Full Screen, hide: \(items)")
        check(footer.status.font == NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), "status font: \(String(describing: footer.status.font))")
        check(footer.allowSystemKeys.isHidden == NativeSystemKeyCapture.isPermitted, "Allow ⌘-Tab… only without Accessibility")
        checkFooter(shown: true, "window")
        check(footer.exitFullScreen.isHidden, "no Exit Full Screen in a window")
        let chrome = viewerWindow.frame.height - content.frame.height
        check(viewer.windowWillResize(viewerWindow, to: NSSize(width: 1000, height: 999)) == NSSize(width: 1000, height: 500 + 34 + chrome),
              "a window keeps the desktop's shape above the footer")

        let proposed: NSApplication.PresentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideDock, .autoHideToolbar]
        let options = viewer.window(viewerWindow, willUseFullScreenPresentationOptions: proposed)
        check(options == [.fullScreen, .hideDock, .hideMenuBar],
              "full screen hides this Mac's menu bar and Dock, with or without Accessibility: \(options)")
        viewer.windowWillEnterFullScreen(note(NSWindow.willEnterFullScreenNotification))
        // AppKit resizes during the transition; the desktop's shape must not
        // make the window taller than the screen.
        let fullScreen = NSSize(width: 1800, height: 1130)
        check(viewer.windowWillResize(viewerWindow, to: fullScreen) == fullScreen, "full screen keeps AppKit's size")
        viewerWindow.setContentSize(fullScreen)
        viewer.windowDidEnterFullScreen(note(NSWindow.didEnterFullScreenNotification))
        checkFooter(shown: true, "full screen")
        check(!footer.exitFullScreen.isHidden, "Exit Full Screen in full screen")

        // View → Diagnostic Footer (⌃⌘D) has no target: AppKit sends it along
        // the key window's responder chain, then to the window's delegate.
        let menuItem = NSMenuItem(title: "Diagnostic Footer", action: #selector(VNCViewerWindow.toggleDiagnosticBar(_:)), keyEquivalent: "d")
        menuItem.keyEquivalentModifierMask = [.control, .command]
        var responder: NSResponder? = viewerWindow.firstResponder
        while let current = responder, !current.responds(to: menuItem.action) { responder = current.nextResponder }
        let target: AnyObject? = responder ?? viewerWindow.delegate
        check(target === viewer, "⌃⌘D reaches the viewer: \(String(describing: target))")
        check(viewer.validateMenuItem(menuItem) && menuItem.state == .on, "Diagnostic Footer enabled and checked")
        check(NSApplication.shared.sendAction(menuItem.action!, to: target, from: menuItem), "⌃⌘D sent")
        checkFooter(shown: false, "⌃⌘D in full screen")
        check(viewer.validateMenuItem(menuItem) && menuItem.state == .off, "Diagnostic Footer unchecked")
        check(NSApplication.shared.sendAction(menuItem.action!, to: target, from: menuItem), "⌃⌘D sent again")
        checkFooter(shown: true, "⌃⌘D again")
        footer.hide.performClick(nil)
        checkFooter(shown: false, "hide chevron")
        viewer.toggleDiagnosticBar(nil)
        check(footerChanges == [false, true, false, true], "each change is remembered: \(footerChanges)")

        viewer.windowWillExitFullScreen(note(NSWindow.willExitFullScreenNotification))
        viewer.windowDidExitFullScreen(note(NSWindow.didExitFullScreenNotification))
        check(footer.exitFullScreen.isHidden && !viewer.isFullScreen, "Exit Full Screen gone after leaving")
        // Leaving sized the window to the tiny desktop; give it a usable size.
        viewerWindow.setContentSize(NSSize(width: 1000, height: 534))
        checkFooter(shown: true, "window again")
        check(viewer.windowWillResize(viewerWindow, to: NSSize(width: 1000, height: 999)).height == 500 + 34 + chrome,
              "the desktop's shape again in a window")
        viewer.close()
        check(viewer.isClosed && !viewer.validateMenuItem(menuItem), "a closed viewer takes no menu actions")

        // On that Mac (1800x1169 points at 2x, a 38-point housing, full screen
        // 1800x1130 below a 39-point row), the virtual screen asked for fills
        // the row and the picture area above the footer exactly, so the footer
        // stays on screen and the desktop's top 78 rows sit beside the housing.
        let notched = CGSize(width: 1800, height: 1169)
        let screen = VNCViewerWindow.virtualScreen(size: notched, safeTop: 38, scale: 2, besideCamera: true, showsFooter: true)
        check(screen == (3600, 2270), "virtual screen with the footer: \(screen)")
        check(VNCViewerWindow.cameraRowRows(remoteHeight: 2270, scale: 2, rowHeight: 39, below: 1130 - 34) == 78, "78 rows beside the housing")
        // ⌃⌘D in full screen: the picture area no longer matches that screen,
        // so the whole desktop fits below the housing.
        check(VNCViewerWindow.cameraRowRows(remoteHeight: 2270, scale: 2, rowHeight: 39, below: 1130) == nil, "no split without the footer")
        let bare = VNCViewerWindow.virtualScreen(size: notched, safeTop: 38, scale: 2, besideCamera: true, showsFooter: false)
        check(bare == (3600, 2338) && VNCViewerWindow.cameraRowRows(remoteHeight: 2338, scale: 2, rowHeight: 39, below: 1130) == 78,
              "virtual screen without the footer: \(bare)")
        check(VNCViewerWindow.virtualScreen(size: notched, safeTop: 38, scale: 2, besideCamera: false, showsFooter: true) == (3600, 2194),
              "virtual screen below the housing")

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
        print("VNC viewer: \(events.count) events, opaque BGRA in two surfaces with catch-up, pointer mapping, keys and releases on close, footer in a window and in full screen with ⌃⌘D, and camera-row sizing passed.")
    }
}
