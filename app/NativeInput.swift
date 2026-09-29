import AppKit
import ApplicationServices

enum NativeInputError: LocalizedError {
    case invalidEvent(String)
    case invalidGeometry
    case accessibilityRequired
    case eventCreationFailed
    case sessionClosed

    var errorDescription: String? {
        switch self {
        case .invalidEvent(let detail): return "Invalid remote input: \(detail)"
        case .invalidGeometry: return "The shared display geometry is unavailable."
        case .accessibilityRequired: return "Allow MacLink in Accessibility on the sharing Mac to control it."
        case .eventCreationFailed: return "macOS could not create the remote input event."
        case .sessionClosed: return "This remote control session has ended."
        }
    }
}

/// Wire flags (ML_MODIFIER_*) are deliberately independent of AppKit's
/// device-specific bits. Rust rejects any other bit.
struct NativeInputModifiers: OptionSet, Equatable {
    let rawValue: UInt32
    static let shift = Self(rawValue: UInt32(ML_MODIFIER_SHIFT))
    static let control = Self(rawValue: UInt32(ML_MODIFIER_CONTROL))
    static let option = Self(rawValue: UInt32(ML_MODIFIER_OPTION))
    static let command = Self(rawValue: UInt32(ML_MODIFIER_COMMAND))
    static let capsLock = Self(rawValue: UInt32(ML_MODIFIER_CAPS_LOCK))
    static let function = Self(rawValue: UInt32(ML_MODIFIER_FUNCTION))

    init(rawValue: UInt32) { self.rawValue = rawValue }
    static func from(_ flags: NSEvent.ModifierFlags) -> Self {
        var value: Self = []
        for (native, wire): (NSEvent.ModifierFlags, Self) in [
            (.shift, .shift), (.control, .control), (.option, .option),
            (.command, .command), (.capsLock, .capsLock), (.function, .function)
        ] where flags.contains(native) { value.insert(wire) }
        return value
    }
    var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        for (wire, native): (Self, CGEventFlags) in [
            (.shift, .maskShift), (.control, .maskControl), (.option, .maskAlternate),
            (.command, .maskCommand), (.capsLock, .maskAlphaShift), (.function, .maskSecondaryFn)
        ] where contains(wire) { flags.insert(native) }
        return flags
    }
}

enum NativeInputKind: UInt8 {
    case keyDown = 1, keyUp, pointerMove, pointerDown, pointerUp, scroll, releaseAll
}

/// One remote input event. Coordinates have a top-left origin in the displayed
/// image, independent of Retina scaling. Rust owns validation and the wire
/// format: construction fails for anything Rust rejects, and fields a kind does
/// not use are nil (zero on the wire), so a value always equals its wire form.
struct NativeInputEvent: Equatable {
    let kind: NativeInputKind
    let keyCode: UInt16?
    let button: UInt8?
    let clickCount: UInt8?
    let x: Double?
    let y: Double?
    let deltaX: Double?
    let deltaY: Double?
    let modifiers: NativeInputModifiers
    let isRepeat: Bool

    /// Button events default to a single click.
    init(kind: NativeInputKind, keyCode: UInt16? = nil, button: UInt8? = nil, clickCount: UInt8? = nil,
         x: Double? = nil, y: Double? = nil, deltaX: Double? = nil, deltaY: Double? = nil,
         modifiers: NativeInputModifiers = [], isRepeat: Bool = false) throws {
        var raw = MLInputEvent()
        raw.kind = kind.rawValue; raw.key_code = keyCode ?? 0; raw.button = button ?? 0
        raw.click_count = clickCount ?? (kind == .pointerDown || kind == .pointerUp ? 1 : 0)
        raw.x = x ?? 0; raw.y = y ?? 0; raw.delta_x = deltaX ?? 0; raw.delta_y = deltaY ?? 0
        raw.modifiers = modifiers.rawValue; raw.is_repeat = isRepeat ? 1 : 0
        try self.init(raw)
    }
    init(_ raw: MLInputEvent) throws {
        var checked = raw
        guard ml_input_event_validate(&checked) == ML_SESSION_OK, let kind = NativeInputKind(rawValue: raw.kind) else {
            throw NativeInputError.invalidEvent("rejected by the session protocol")
        }
        let key = kind == .keyDown || kind == .keyUp, buttons = kind == .pointerDown || kind == .pointerUp
        let pointer = !key && kind != .releaseAll
        self.kind = kind
        keyCode = key ? raw.key_code : nil
        button = buttons ? raw.button : nil
        clickCount = buttons ? raw.click_count : nil
        x = pointer ? raw.x : nil
        y = pointer ? raw.y : nil
        deltaX = kind == .scroll ? raw.delta_x : nil
        deltaY = kind == .scroll ? raw.delta_y : nil
        modifiers = NativeInputModifiers(rawValue: raw.modifiers)
        isRepeat = raw.is_repeat == 1
    }
    var raw: MLInputEvent {
        var raw = MLInputEvent()
        raw.kind = kind.rawValue; raw.key_code = keyCode ?? 0; raw.button = button ?? 0; raw.click_count = clickCount ?? 0
        raw.x = x ?? 0; raw.y = y ?? 0; raw.delta_x = deltaX ?? 0; raw.delta_y = deltaY ?? 0
        raw.modifiers = modifiers.rawValue; raw.is_repeat = isRepeat ? 1 : 0
        return raw
    }
}

enum NativeInputGeometry {
    static func isValid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.size.width >= 1 && rect.size.height >= 1 && rect.maxX.isFinite && rect.maxY.isFinite
    }

    static func point(x: Double, y: Double, displayBounds: CGRect) throws -> CGPoint {
        guard isValid(displayBounds), x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw NativeInputError.invalidGeometry
        }
        // The far edge belongs to a neighboring display; keep events inside the
        // selected display, including normalized coordinates of exactly 1.
        return CGPoint(x: displayBounds.minX + x * max(0, displayBounds.width - 1),
                       y: displayBounds.minY + y * max(0, displayBounds.height - 1))
    }

    static func normalized(point: CGPoint, contentRect: CGRect, flipped: Bool, clamp: Bool = false) -> CGPoint? {
        guard isValid(contentRect), point.x.isFinite, point.y.isFinite else { return nil }
        let x = (point.x - contentRect.minX) / contentRect.width
        let y = flipped ? (point.y - contentRect.minY) / contentRect.height
            : (contentRect.maxY - point.y) / contentRect.height
        guard clamp || ((0...1).contains(x) && (0...1).contains(y)) else { return nil }
        return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }
}

/// Call on the viewer's UI thread, only for events delivered to its focused view.
/// No event taps, global monitors, Accessibility prompts, or system shortcuts.
final class NativeInputEncoder {
    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<UInt8>()

    static func isModifierKey(_ code: UInt16) -> Bool { modifierFamily(code) != nil }
    private static func modifierFamily(_ code: UInt16) -> NativeInputModifiers? {
        switch code {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 57: return .capsLock
        case 63: return .function
        default: return nil
        }
    }
    // Public IOKit IOLLEvent.h device masks, never serialized over the wire.
    private static func sideMasks(_ code: UInt16) -> (own: UInt64, family: UInt64)? {
        switch code {
        case 55: return (0x08, 0x18)
        case 54: return (0x10, 0x18)
        case 56: return (0x02, 0x06)
        case 60: return (0x04, 0x06)
        case 58: return (0x20, 0x60)
        case 61: return (0x40, 0x60)
        case 59: return (0x01, 0x2001)
        case 62: return (0x2000, 0x2001)
        default: return nil
        }
    }

    /// Separate pure entry point so left/right modifier transitions can be tested
    /// without creating NSEvents or reading the user's keyboard state.
    func modifierEvent(keyCode: UInt16, modifiers: NativeInputModifiers, deviceFlags: UInt64) -> NativeInputEvent? {
        guard let family = Self.modifierFamily(keyCode) else { return nil }
        let down: Bool
        if !modifiers.contains(family) { down = false }
        else if let masks = Self.sideMasks(keyCode), deviceFlags & masks.family != 0 {
            down = deviceFlags & masks.own != 0
        } else if Self.sideMasks(keyCode) != nil {
            // Some synthesized NSEvents omit side bits. flagsChanged still names
            // the changing physical key, so toggle only that key's state.
            down = !heldKeys.contains(keyCode)
        } else { down = true }
        guard down != heldKeys.contains(keyCode),
              let event = try? NativeInputEvent(kind: down ? .keyDown : .keyUp, keyCode: keyCode, modifiers: modifiers) else { return nil }
        if down { heldKeys.insert(keyCode) } else { heldKeys.remove(keyCode) }
        return event
    }

    func encode(_ event: NSEvent, in view: NSView, contentRect: CGRect) -> NativeInputEvent? {
        let modifiers = NativeInputModifiers.from(event.modifierFlags)
        switch event.type {
        case .flagsChanged:
            return modifierEvent(keyCode: event.keyCode, modifiers: modifiers, deviceFlags: UInt64(event.modifierFlags.rawValue))
        case .keyDown, .keyUp:
            let down = event.type == .keyDown
            guard let input = try? NativeInputEvent(kind: down ? .keyDown : .keyUp, keyCode: event.keyCode,
                                                    modifiers: modifiers, isRepeat: down && event.isARepeat) else { return nil }
            if down { heldKeys.insert(event.keyCode) } else { heldKeys.remove(event.keyCode) }
            return input
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel:
            let kind: NativeInputKind
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .pointerDown
            case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .pointerUp
            case .scrollWheel: kind = .scroll
            default: kind = .pointerMove
            }
            let isButton = kind == .pointerDown || kind == .pointerUp
            guard !isButton || (0...2).contains(event.buttonNumber) else { return nil }
            let button = isButton ? UInt8(event.buttonNumber) : nil
            // Continue drags and their release outside a letterboxed image. New
            // clicks and scrolls in the black bars are intentionally ignored.
            let clamp = (kind == .pointerMove && !heldButtons.isEmpty)
                || (kind == .pointerUp && button.map { heldButtons.contains($0) } == true)
            guard let position = NativeInputGeometry.normalized(point: view.convert(event.locationInWindow, from: nil),
                                                                 contentRect: contentRect, flipped: view.isFlipped, clamp: clamp) else { return nil }
            let scale = event.type == .scrollWheel && !event.hasPreciseScrollingDeltas ? 10.0 : 1.0
            let dx = kind == .scroll ? min(1200, max(-1200, event.scrollingDeltaX * scale)) : nil
            let dy = kind == .scroll ? min(1200, max(-1200, event.scrollingDeltaY * scale)) : nil
            let clicks = isButton ? UInt8(min(3, max(1, event.clickCount))) : nil
            guard let input = try? NativeInputEvent(kind: kind, button: button, clickCount: clicks, x: position.x, y: position.y,
                                                    deltaX: dx, deltaY: dy, modifiers: modifiers) else { return nil }
            if let button {
                if kind == .pointerDown { heldButtons.insert(button) } else { heldButtons.remove(button) }
            }
            return input
        default: return nil
        }
    }

    /// Send this before focus loss/disconnect; also clears local modifier tracking.
    func releaseAll() -> NativeInputEvent {
        heldKeys.removeAll(); heldButtons.removeAll()
        // All fields use validated, fixed protocol values.
        return try! NativeInputEvent(kind: .releaseAll)
    }
}

/// NSApplication does not dispatch keyUp: to responders while Command is held.
/// Without these releases the host keeps the key pressed after a shortcut and
/// ignores that key's next press (a second Cmd-Z or Cmd-V does nothing). A local
/// monitor still observes them. Only Command releases aimed at the focused view
/// are forwarded; a duplicate release is harmless because both ends drop it.
final class NativeCommandKeyUpMonitor {
    private var monitor: Any?

    init(view: NSView, forward: @escaping (NSEvent) -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak view] event in
            if let view, let window = view.window, event.window === window, window.firstResponder === view,
               event.modifierFlags.contains(.command) { forward(event) }
            return event
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    deinit { stop() }
}

/// The host's held-input state, owned by Rust: unknown releases and duplicate
/// presses can never release a key or button this connection did not press.
/// accept stages a transition; commit only after posting what it returned.
final class NativeInputReducer {
    private let state = ml_input_state_new()!
    private var output = [MLInputEvent](repeating: MLInputEvent(), count: Int(ML_INPUT_MAX_EVENTS))
    deinit { ml_input_state_free(state) }

    /// Returns the events to post and the buttons held afterward.
    func accept(_ event: NativeInputEvent, now: TimeInterval) throws -> ([NativeInputEvent], Set<UInt8>) {
        var raw = event.raw, count = 0, held: UInt8 = 0
        let status = ml_input_state_accept(state, &raw, now, &output, output.count, &count, &held)
        switch Int(status) {
        case ML_SESSION_OK: break
        case ML_SESSION_CLOSED: throw NativeInputError.sessionClosed
        default: throw NativeInputError.invalidEvent("rejected by the session protocol")
        }
        return (try events(count), Set((0..<3).filter { held & (1 << $0) != 0 }.map(UInt8.init)))
    }
    func commit() { _ = ml_input_state_commit(state) }
    /// Forgets every held key and button and returns the releases to post.
    func releaseAll() -> [NativeInputEvent] {
        var count = 0
        guard ml_input_state_release_all(state, &output, output.count, &count) == ML_SESSION_OK else { return [] }
        return (try? events(count)) ?? []
    }
    /// Ends the state permanently; later accepts fail with sessionClosed.
    func stop() -> [NativeInputEvent] {
        var count = 0
        guard ml_input_state_stop(state, &output, output.count, &count) == ML_SESSION_OK else { return [] }
        return (try? events(count)) ?? []
    }
    private func events(_ count: Int) throws -> [NativeInputEvent] {
        try output.prefix(count).map { try NativeInputEvent($0) }
    }
}

/// One injector per authenticated host session. apply/releaseAll are serialized
/// internally, including when network input races a main-thread Stop action.
/// Call releaseAll on disconnect, focus loss, timeout, display change, and Stop.
final class NativeInputInjector {
    private let lock = NSLock()
    private let reducer = NativeInputReducer()
    private let source = CGEventSource(stateID: .privateState)
    private var lastDisplayBounds: CGRect?

    static var isTrusted: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }
    var isTrusted: Bool { Self.isTrusted }

    func apply(_ event: NativeInputEvent, displayBounds: CGRect) throws {
        lock.lock(); defer { lock.unlock() }
        do {
            guard Self.isTrusted else { throw NativeInputError.accessibilityRequired }
            if event.kind == .releaseAll { releaseLocked(); return }
            guard NativeInputGeometry.isValid(displayBounds) else { throw NativeInputError.invalidGeometry }
            if let previous = lastDisplayBounds, previous != displayBounds { releaseLocked() }
            let (accepted, heldButtons) = try reducer.accept(event, now: ProcessInfo.processInfo.systemUptime)
            let events = try accepted.map { try makeEvent($0, displayBounds: displayBounds, heldButtons: heldButtons) }
            for native in events { native.post(tap: .cghidEventTap) }
            reducer.commit(); lastDisplayBounds = displayBounds
        } catch {
            releaseLocked()
            throw error
        }
    }

    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        releaseLocked()
    }

    /// Permanently end this injector before discarding a host connection. Queued
    /// network callbacks cannot re-press input after disconnect or the Stop button.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        postReleasesLocked(reducer.stop())
    }

    private func releaseLocked() {
        postReleasesLocked(reducer.releaseAll())
    }

    private func postReleasesLocked(_ releases: [NativeInputEvent]) {
        // Permission can be revoked while keys are down. Always forget held state;
        // posting cleanup is best effort only while macOS still permits it.
        guard Self.isTrusted, let bounds = lastDisplayBounds else { return }
        for event in releases {
            if let native = try? makeEvent(event, displayBounds: bounds, heldButtons: []) { native.post(tap: .cghidEventTap) }
        }
    }

    private func makeEvent(_ event: NativeInputEvent, displayBounds: CGRect, heldButtons: Set<UInt8>) throws -> CGEvent {
        guard let source else { throw NativeInputError.eventCreationFailed }
        let native: CGEvent?
        switch event.kind {
        case .keyDown, .keyUp:
            guard let code = event.keyCode else { throw NativeInputError.eventCreationFailed }
            native = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: event.kind == .keyDown)
            if NativeInputEncoder.isModifierKey(code) { native?.type = .flagsChanged }
            native?.setIntegerValueField(.keyboardEventAutorepeat, value: event.isRepeat ? 1 : 0)
        case .pointerMove, .pointerDown, .pointerUp:
            guard let x = event.x, let y = event.y else { throw NativeInputError.eventCreationFailed }
            let point = try NativeInputGeometry.point(x: x, y: y, displayBounds: displayBounds)
            let button = event.button ?? heldButtons.sorted().first ?? 0
            let type: CGEventType
            switch event.kind {
            case .pointerDown: type = button == 0 ? .leftMouseDown : button == 1 ? .rightMouseDown : .otherMouseDown
            case .pointerUp: type = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
            default:
                type = heldButtons.isEmpty ? .mouseMoved : button == 0 ? .leftMouseDragged : button == 1 ? .rightMouseDragged : .otherMouseDragged
            }
            guard let mouseButton = CGMouseButton(rawValue: UInt32(button)) else { throw NativeInputError.eventCreationFailed }
            native = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton)
            if let clicks = event.clickCount { native?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)) }
        case .scroll:
            guard let x = event.x, let y = event.y, let dx = event.deltaX, let dy = event.deltaY else { throw NativeInputError.eventCreationFailed }
            native = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                             wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)
            native?.location = try NativeInputGeometry.point(x: x, y: y, displayBounds: displayBounds)
            native?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
            native?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
            native?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        case .releaseAll: throw NativeInputError.eventCreationFailed
        }
        guard let native else { throw NativeInputError.eventCreationFailed }
        native.flags = event.modifiers.cgFlags
        return native
    }

    deinit { stop() }
}
