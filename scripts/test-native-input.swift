import AppKit
import Foundation

@main
enum NativeInputTests {
    static var checks = 0
    static func require(_ value: Bool, _ message: String) {
        checks += 1
        precondition(value, message)
    }
    static func rejects(_ body: () throws -> Void, _ message: String) {
        do { try body(); preconditionFailure(message) }
        catch { checks += 1 }
    }
    static func close(_ left: CGFloat, _ right: CGFloat) -> Bool { abs(left - right) < 0.000_001 }

    static func main() throws {
        // No injector instance, permission request, global capture, or event post
        // is used by this executable. Validation and held-input policy are Rust's
        // (cargo test -p maclink-session); these checks cover the Swift boundary.
        let down = try NativeInputEvent(kind: .keyDown, keyCode: 0, modifiers: [.command, .shift])
        let up = try NativeInputEvent(kind: .keyUp, keyCode: 0)
        let move = try NativeInputEvent(kind: .pointerMove, x: 0.25, y: 0.75)
        let click = try NativeInputEvent(kind: .pointerDown, button: 0, clickCount: 2, x: 0.25, y: 0.75)
        let scroll = try NativeInputEvent(kind: .scroll, x: 1, y: 0, deltaX: -0.75, deltaY: 12.5)
        let clear = try NativeInputEvent(kind: .releaseAll)
        for event in [down, up, move, click, scroll, clear] {
            require(try NativeInputEvent(event.raw) == event, "Every event round-trips the C ABI exactly")
        }
        require(click.clickCount == 2, "Double clicks preserve their native count")
        require(try NativeInputEvent(kind: .pointerUp, button: 2, x: 0, y: 1).clickCount == 1,
                "An ordinary click defaults to one")
        require(try NativeInputEvent(kind: .pointerMove, x: 0.5) == NativeInputEvent(kind: .pointerMove, x: 0.5, y: 0),
                "Absent fields are zero on the wire, so values are canonical")
        require(move.keyCode == nil && move.button == nil && down.x == nil && scroll.deltaY == 12.5,
                "Fields a kind does not use are nil")
        require(NativeInputModifiers.command.rawValue == UInt32(ML_MODIFIER_COMMAND)
                && NativeInputKind.releaseAll.rawValue == UInt8(ML_INPUT_RELEASE_ALL), "Swift and Rust input values agree")

        rejects({ _ = try NativeInputEvent(kind: .keyDown, keyCode: 128) }, "Reject unsupported key codes")
        rejects({ _ = try NativeInputEvent(kind: .keyUp, keyCode: 0, isRepeat: true) }, "Key release cannot repeat")
        rejects({ _ = try NativeInputEvent(kind: .keyDown, keyCode: 56, isRepeat: true) }, "Modifiers cannot repeat")
        rejects({ _ = try NativeInputEvent(kind: .keyDown, keyCode: 0, x: 0.5, y: 0) }, "Keyboard events reject pointer fields")
        rejects({ _ = try NativeInputEvent(kind: .keyDown, keyCode: 0, modifiers: .init(rawValue: 64)) }, "Reject unknown modifier bits")
        rejects({ _ = try NativeInputEvent(kind: .pointerDown, button: 3, x: 0, y: 0) }, "Only three pointer buttons are supported")
        rejects({ _ = try NativeInputEvent(kind: .pointerDown, button: 0, clickCount: 4, x: 0, y: 0) }, "Bound click counts")
        rejects({ _ = try NativeInputEvent(kind: .pointerMove, button: 1, x: 0, y: 0) }, "Move cannot smuggle a button press")
        rejects({ _ = try NativeInputEvent(kind: .pointerMove, x: -.infinity, y: 0) }, "Reject infinite positions")
        rejects({ _ = try NativeInputEvent(kind: .pointerMove, x: .nan, y: 0) }, "Reject NaN positions")
        rejects({ _ = try NativeInputEvent(kind: .pointerMove, x: 1.01, y: 0) }, "Reject out-of-range positions")
        rejects({ _ = try NativeInputEvent(kind: .scroll, x: 0, y: 0, deltaX: 0, deltaY: 1201) }, "Bound scroll distance")
        rejects({ _ = try NativeInputEvent(kind: .scroll, x: 0, y: 0, deltaX: .nan, deltaY: 0) }, "Reject NaN scroll")
        rejects({ _ = try NativeInputEvent(kind: .releaseAll, keyCode: 55) }, "Release-all contains no arbitrary key")
        rejects({ _ = try NativeInputEvent(kind: .releaseAll, modifiers: .command) }, "Release-all cannot leave modifiers set")
        var unknownKind = down.raw; unknownKind.kind = 11
        rejects({ _ = try NativeInputEvent(unknownKind) }, "Reject unknown kinds from the C ABI")
        var reserved = down.raw; reserved.reserved.0 = 1
        rejects({ _ = try NativeInputEvent(reserved) }, "Reject nonzero reserved bytes")

        // Magnify and rotate carry a phase in `button` and a change in `deltaX`.
        let pinch = try NativeInputEvent(kind: .magnify, button: UInt8(ML_GESTURE_PHASE_CHANGED), x: 0.5, y: 0.5, deltaX: -0.12)
        let turn = try NativeInputEvent(kind: .rotate, button: UInt8(ML_GESTURE_PHASE_BEGAN), x: 0.2, y: 0.3, deltaX: 0)
        let smartZoom = try NativeInputEvent(kind: .smartMagnify, x: 0.4, y: 0.6)
        for event in [pinch, turn, smartZoom] {
            require(try NativeInputEvent(event.raw) == event && event.kind.isGesture, "Gestures round-trip the C ABI exactly")
        }
        require(pinch.button == UInt8(ML_GESTURE_PHASE_CHANGED) && pinch.deltaX == -0.12 && smartZoom.button == nil,
                "Gesture phases and values survive")
        require(NativeInputKind.magnify.rawValue == UInt8(ML_INPUT_MAGNIFY) && NativeInputKind.rotate.rawValue == UInt8(ML_INPUT_ROTATE)
                && NativeInputKind.smartMagnify.rawValue == UInt8(ML_INPUT_SMART_MAGNIFY) && !NativeInputKind.scroll.isGesture,
                "Swift and Rust gesture kinds agree")
        rejects({ _ = try NativeInputEvent(kind: .magnify, button: 3, x: 0, y: 0, deltaX: 0.1) }, "A gesture has one phase")
        rejects({ _ = try NativeInputEvent(kind: .magnify, button: 2, x: 0, y: 0, deltaX: 5.5) }, "Bound magnification")
        rejects({ _ = try NativeInputEvent(kind: .rotate, button: 2, x: 0, y: 0, deltaX: .nan) }, "Reject NaN rotation")
        rejects({ _ = try NativeInputEvent(kind: .smartMagnify, button: 1, x: 0, y: 0) }, "Smart zoom has no phase")

        let bounds = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        require(try NativeInputGeometry.point(x: 0, y: 0, displayBounds: bounds) == bounds.origin,
                "Normalized origin maps to selected display origin, including negatives")
        require(try NativeInputGeometry.point(x: 1, y: 1, displayBounds: bounds) == CGPoint(x: -1, y: 879),
                "Far edge stays in the selected display")
        let center = try NativeInputGeometry.point(x: 0.5, y: 0.5, displayBounds: bounds)
        require(close(center.x, -960.5) && close(center.y, 339.5), "Center maps independently of framebuffer density")
        rejects({ _ = try NativeInputGeometry.point(x: 0, y: 0, displayBounds: .zero) }, "Zero display area rejected")
        rejects({ _ = try NativeInputGeometry.point(x: 0, y: 0, displayBounds: CGRect(x: 0, y: 0, width: -1, height: 2)) }, "Negative display dimensions rejected")
        rejects({ _ = try NativeInputGeometry.point(x: 0, y: 0, displayBounds: CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20)) }, "Nonfinite display origin rejected")
        rejects({ _ = try NativeInputGeometry.point(x: .nan, y: 0, displayBounds: bounds) }, "Geometry independently validates coordinates")
        let content = CGRect(x: 20, y: 30, width: 800, height: 450)
        require(NativeInputGeometry.normalized(point: CGPoint(x: 20, y: 480), contentRect: content, flipped: false) == .zero,
                "AppKit bottom-left coordinates map to remote top-left")
        require(NativeInputGeometry.normalized(point: CGPoint(x: 20, y: 30), contentRect: content, flipped: true) == .zero,
                "Flipped views use a top-left origin directly")
        require(NativeInputGeometry.normalized(point: CGPoint(x: 420, y: 255), contentRect: content, flipped: false) == CGPoint(x: 0.5, y: 0.5),
                "Letterboxed image center maps to normalized center")
        require(NativeInputGeometry.normalized(point: CGPoint(x: 5, y: 255), contentRect: content, flipped: false) == nil,
                "Letterbox clicks are ignored")
        require(NativeInputGeometry.normalized(point: CGPoint(x: -100, y: 900), contentRect: content, flipped: false, clamp: true) == .zero,
                "Drag release outside the image clamps to the image edge")
        require(NativeInputGeometry.normalized(point: CGPoint(x: CGFloat.nan, y: 0), contentRect: content, flipped: true, clamp: true) == nil,
                "Even clamped coordinates must be finite")

        let modifiers = NativeInputEncoder()
        require(modifiers.modifierEvent(keyCode: 56, modifiers: .shift, deviceFlags: 0x02)?.kind == .keyDown,
                "Left Shift presses independently")
        require(modifiers.modifierEvent(keyCode: 60, modifiers: .shift, deviceFlags: 0x06)?.kind == .keyDown,
                "Right Shift presses while Left Shift remains down")
        let leftUp = modifiers.modifierEvent(keyCode: 56, modifiers: .shift, deviceFlags: 0x04)
        require(leftUp?.kind == .keyUp && leftUp?.modifiers == .shift, "Left Shift releases while Right Shift preserves the family flag")
        require(modifiers.modifierEvent(keyCode: 60, modifiers: [], deviceFlags: 0)?.kind == .keyUp, "Right Shift release clears its key")
        require(modifiers.modifierEvent(keyCode: 60, modifiers: [], deviceFlags: 0) == nil, "Repeated modifier releases are ignored")
        for (left, right, family, leftMask, rightMask): (UInt16, UInt16, NativeInputModifiers, UInt64, UInt64) in [
            (55, 54, .command, 0x08, 0x10), (58, 61, .option, 0x20, 0x40), (59, 62, .control, 0x01, 0x2000)
        ] {
            require(modifiers.modifierEvent(keyCode: left, modifiers: family, deviceFlags: leftMask)?.kind == .keyDown, "Left modifier key down")
            require(modifiers.modifierEvent(keyCode: right, modifiers: family, deviceFlags: leftMask | rightMask)?.kind == .keyDown, "Right modifier key down")
            require(modifiers.modifierEvent(keyCode: left, modifiers: family, deviceFlags: rightMask)?.kind == .keyUp, "Left modifier releases independently")
            require(modifiers.modifierEvent(keyCode: right, modifiers: [], deviceFlags: 0)?.kind == .keyUp, "Right modifier releases independently")
        }
        require(modifiers.modifierEvent(keyCode: 56, modifiers: .shift, deviceFlags: 0)?.kind == .keyDown, "Missing side bits use physical key edges")
        require(modifiers.modifierEvent(keyCode: 60, modifiers: .shift, deviceFlags: 0)?.kind == .keyDown, "Fallback tracks both physical sides")
        require(modifiers.modifierEvent(keyCode: 56, modifiers: .shift, deviceFlags: 0)?.kind == .keyUp, "Fallback can release one side while family stays set")
        require(modifiers.modifierEvent(keyCode: 60, modifiers: [], deviceFlags: 0)?.kind == .keyUp, "Fallback releases final side")
        require(modifiers.modifierEvent(keyCode: 57, modifiers: .capsLock, deviceFlags: 0)?.kind == .keyDown, "Caps Lock flag is represented")
        require(modifiers.modifierEvent(keyCode: 57, modifiers: [], deviceFlags: 0)?.kind == .keyUp, "Caps Lock flag clears")
        require(modifiers.modifierEvent(keyCode: 63, modifiers: .function, deviceFlags: 0)?.kind == .keyDown, "Function key is represented")
        require(modifiers.modifierEvent(keyCode: 63, modifiers: [], deviceFlags: 0)?.kind == .keyUp, "Function key clears")
        require(modifiers.modifierEvent(keyCode: 0, modifiers: .shift, deviceFlags: 0) == nil, "Unknown flagsChanged key is ignored")
        _ = modifiers.modifierEvent(keyCode: 55, modifiers: .command, deviceFlags: 0x08)
        require(modifiers.releaseAll() == clear, "Focus loss encodes explicit releaseAll")
        require(modifiers.modifierEvent(keyCode: 55, modifiers: .command, deviceFlags: 0x08)?.kind == .keyDown,
                "Focus loss clears encoder modifier state")
        // AppKit reads the private gesture fields back as the real event types;
        // nothing is posted.
        let gestureSource = CGEventSource(stateID: .privateState)
        require(gestureSource != nil, "A private event source exists")
        func appKit(_ event: NativeInputEvent) throws -> NSEvent? {
            try gestureSource.flatMap { try NativeInputInjector.gestureEvent(event, source: $0, displayBounds: bounds) }
                .flatMap { NSEvent(cgEvent: $0) }
        }
        let pinchEvent = try appKit(pinch), turnEvent = try appKit(turn), smartEvent = try appKit(smartZoom)
        require(pinchEvent?.type == .magnify && pinchEvent.map { close($0.magnification, -0.12) } == true
                && pinchEvent?.phase == .changed, "A pinch arrives as a magnify event with its phase and value")
        require(turnEvent?.type == .rotate && turnEvent?.phase == .began, "A rotation arrives as a rotate event")
        require(smartEvent?.type == .smartMagnify, "A smart zoom arrives as a smart magnify event")
        let rotated = try appKit(try NativeInputEvent(kind: .rotate, button: UInt8(ML_GESTURE_PHASE_CHANGED), x: 0, y: 1, deltaX: 12.5))
        require(rotated.map { abs($0.rotation - 12.5) < 0.001 } == true, "Rotation degrees survive")
        require(NativeInputModifiers.from([.command, .shift, .numericPad]) == [.command, .shift], "Only canonical flags are serialized")
        require(NativeInputModifiers([.command, .shift]).cgFlags == [.maskCommand, .maskShift], "Wire flags map to explicit CG flags")

        // The Rust reducer stages transitions; the injector commits after posting.
        let reducer = NativeInputReducer()
        require(try reducer.accept(up, now: 1).0.isEmpty, "Never release an untracked keyboard key")
        require(try reducer.accept(down, now: 1).0 == [down], "First key press is forwarded")
        require(reducer.releaseAll().isEmpty, "An uncommitted press is not held")
        _ = try reducer.accept(down, now: 1); reducer.commit()
        require(try reducer.accept(down, now: 1.001).0.isEmpty, "Duplicate key down is idempotent")
        let press = try reducer.accept(click, now: 2)
        require(press.0 == [click] && press.1 == [0], "Button presses report the held buttons for drags")
        reducer.commit()
        _ = try reducer.accept(try NativeInputEvent(kind: .pointerMove, x: 0.9, y: 0.1), now: 2); reducer.commit()
        let releases = reducer.releaseAll()
        require(releases.count == 2 && releases[0] == up, "Cleanup releases ordinary keys first")
        require(releases[1].kind == .pointerUp && releases[1].button == 0 && releases[1].x == 0.9 && releases[1].y == 0.1,
                "Cleanup releases held mouse button at its latest position")
        require(releases.allSatisfy { $0.modifiers.isEmpty }, "Cleanup cannot retain stale flags")
        _ = try reducer.accept(down, now: 3); reducer.commit()
        require(reducer.stop() == [up], "Stop releases current keys")
        rejects({ _ = try reducer.accept(down, now: 4) }, "Queued input cannot press keys after Stop")
        require(reducer.stop().isEmpty && reducer.releaseAll().isEmpty, "Stop and cleanup stay idempotent")
        let gestures = NativeInputReducer()
        require(try gestures.accept(pinch, now: 1).0.isEmpty, "A gesture change without a beginning is ignored")
        _ = try gestures.accept(turn, now: 1); gestures.commit()
        require(try gestures.accept(smartZoom, now: 1).0.isEmpty, "One gesture at a time")
        let ended = gestures.releaseAll()
        require(ended.count == 1 && ended[0].kind == .rotate && ended[0].button == UInt8(ML_GESTURE_PHASE_ENDED),
                "Cleanup ends an open gesture")
        // The system-shortcut tap keeps only the escape chords local. No tap is
        // installed here; this covers the Swift boundary to Rust's rule.
        let keepsLocal = NativeSystemKeyCapture.keepsLocal
        require(keepsLocal(53, [.command, .option]) && keepsLocal(53, [.command, .option, .shift]),
                "Force Quit stays on the viewing Mac")
        require(keepsLocal(12, [.control, .command]) && keepsLocal(3, [.control, .command]) && keepsLocal(3, .function),
                "Lock Screen and full-screen chords stay on the viewing Mac")
        require(!keepsLocal(48, .command) && !keepsLocal(48, [.command, .shift]) && !keepsLocal(49, .command)
                && !keepsLocal(53, .command) && !keepsLocal(12, .command),
                "⌘-Tab, Spotlight, ⌘-Esc and ⌘-Q go to the remote Mac")
        require(NativeSystemKeyCapture().isRunning == false, "A new capture installs no tap until started")
        let dispatch = testCommandKeyUps()
        print("Native input tests passed: \(checks) checks; validation, wire round-trips, geometry, left/right modifiers, the Rust input boundary, and \(dispatch). No permissions requested or system events posted.")
    }

    /// In-process AppKit dispatch through an off-screen window that is never
    /// activated. Events go to this process's own queue, never to CGEvent.
    static func testCommandKeyUps() -> String {
        guard CGSessionCopyCurrentDictionary() != nil else { return "Command key-up dispatch skipped (no window server session)" }
        final class Target: NSView {
            var keyUps: [UInt16] = []
            override var acceptsFirstResponder: Bool { true }
            override func keyUp(with event: NSEvent) { keyUps.append(event.keyCode) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 64, height: 64),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Off screen and never activated; ordering in lets AppKit route key events.
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let target = Target(frame: window.contentView!.bounds), other = Target(frame: .zero)
        window.contentView!.addSubview(target); window.contentView!.addSubview(other)
        var forwarded: [UInt16] = []
        let monitor = NativeCommandKeyUpMonitor(view: target) { forwarded.append($0.keyCode) }
        func key(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, _ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c",
                             isARepeat: false, keyCode: code)!
        }
        func pump(_ events: [NSEvent]) {
            for event in events { app.postEvent(event, atStart: false) }
            // A trailing marker ends the pump without relying on timing.
            app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, subtype: 7, data1: 0, data2: 0)!, atStart: false)
            let deadline = Date().addingTimeInterval(3)
            while let next = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
                if next.type == .applicationDefined && next.subtype.rawValue == 7 { return }
                app.sendEvent(next)
            }
            preconditionFailure("AppKit event pump timed out")
        }
        window.makeFirstResponder(target)
        pump([key(.keyDown, .command, 8), key(.keyUp, .command, 8), key(.keyDown, [], 9), key(.keyUp, [], 9)])
        require(forwarded == [8], "Command key releases reach the focused remote view")
        require(target.keyUps.contains(9), "Ordinary key releases keep normal responder delivery")
        window.makeFirstResponder(other)
        pump([key(.keyUp, .command, 8)])
        require(forwarded == [8], "Command key releases are not forwarded when the remote view lacks focus")
        window.makeFirstResponder(target); monitor.stop()
        pump([key(.keyUp, .command, 8)])
        require(forwarded == [8], "A stopped monitor forwards nothing")
        return "Command key-up dispatch"
    }
}
