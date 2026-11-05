import AppKit
import IOSurface
import QuartzCore

/// Mooring's own viewer for VNC servers that are not Macs, such as wayvnc on
/// Linux, reached through Mooring's SSH tunnel.
///
/// Rust (`ml_vnc_*`, crate mooring-vnc) owns the protocol, the RSA-AES
/// sign-in, decoding, key mapping and the failed-sign-in budget. This file
/// only copies changed pixels into an IOSurface each display refresh and
/// forwards AppKit events. It never stores the password: the bytes are handed
/// to Rust, which wipes them before returning.
final class VNCView: NSView {
    var sessionID: UInt64 = 0
    /// Called once, when the first picture is on screen.
    var onFirstPicture: (() -> Void)?
    private var shownPicture = false
    /// The remote desktop's size in pixels, once known.
    var remoteSize: CGSize { CGSize(width: surfaceSize.width, height: surfaceSize.height) }
    /// Two surfaces, swapped on each change: Core Animation shows a surface
    /// only when it is assigned as contents, so it is never written while shown.
    private var surfaces: [IOSurface] = []
    private var front = 0
    /// The region the back surface still lacks: the last change, which went
    /// only to the surface now in front.
    private var stale = MLVncRect()
    private var surfaceSize = (width: 0, height: 0)
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        setAccessibilityLabel("Remote desktop")
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func allocate() -> Bool {
        var width: UInt32 = 0, height: UInt32 = 0
        guard ml_vnc_frame_size(sessionID, &width, &height) == 0, width > 0, height > 0 else { return false }
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: Int(width), .height: Int(height), .bytesPerElement: 4, .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        guard let first = IOSurface(properties: properties), let second = IOSurface(properties: properties),
              first.bytesPerRow == second.bytesPerRow else { return false }
        surfaces = [first, second]
        front = 0
        stale = MLVncRect()
        surfaceSize = (Int(width), Int(height))
        return true
    }

    /// Copy what changed since the last refresh. Called once per frame.
    func refresh() {
        guard sessionID != 0 else { return }
        if surfaces.isEmpty && !allocate() { return }
        let shown = surfaces[front], back = surfaces[1 - front]
        back.lock(options: [], seed: nil)
        defer { back.unlock(options: [], seed: nil) }
        if stale.width > 0 && stale.height > 0 {
            shown.lock(options: .readOnly, seed: nil)
            let stride = back.bytesPerRow, row = Int(stale.width) * 4
            for y in Int(stale.y)..<Int(stale.y + stale.height) {
                let offset = y * stride + Int(stale.x) * 4
                memcpy(back.baseAddress + offset, shown.baseAddress + offset, row)
            }
            shown.unlock(options: .readOnly, seed: nil)
            stale = MLVncRect()
        }
        var region = MLVncRect()
        let status = ml_vnc_copy_changes(sessionID, back.baseAddress.assumingMemoryBound(to: UInt8.self),
                                         back.bytesPerRow, UInt32(surfaceSize.width), UInt32(surfaceSize.height), &region)
        switch status {
        case Int32(ML_VNC_COPIED):
            layer?.contents = back
            front = 1 - front
            stale = region
            if !shownPicture { shownPicture = true; onFirstPicture?() }
        case Int32(ML_VNC_RESIZED):
            surfaces = []
        default:
            break
        }
    }

    func clear() {
        sessionID = 0
        surfaces = []
        layer?.contents = nil
    }

    /// The event's position in remote desktop pixels, given the aspect fit.
    private func remotePoint(_ event: NSEvent) -> (Double, Double) {
        let point = convert(event.locationInWindow, from: nil)
        let width = Double(max(surfaceSize.width, 1)), height = Double(max(surfaceSize.height, 1))
        let scale = min(Double(bounds.width) / width, Double(bounds.height) / height)
        guard scale > 0 else { return (0, 0) }
        let left = (Double(bounds.width) - width * scale) / 2
        let bottom = (Double(bounds.height) - height * scale) / 2
        return ((Double(point.x) - left) / scale, height - (Double(point.y) - bottom) / scale)
    }

    /// AppKit's pressed buttons as VNC's: 1 left, 2 middle, 4 right.
    private var buttons: UInt8 {
        let pressed = NSEvent.pressedMouseButtons
        return (pressed & 1 != 0 ? 1 : 0) | (pressed & 4 != 0 ? 2 : 0) | (pressed & 2 != 0 ? 4 : 0)
    }

    private func pointer(_ event: NSEvent) {
        guard sessionID != 0 else { return }
        let (x, y) = remotePoint(event)
        _ = ml_vnc_pointer(sessionID, x, y, buttons)
    }

    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event) }
    override func mouseUp(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDown(with event: NSEvent) { pointer(event) }
    override func rightMouseUp(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDown(with event: NSEvent) { pointer(event) }
    override func otherMouseUp(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }

    override func scrollWheel(with event: NSEvent) {
        guard sessionID != 0 else { return }
        pointer(event)
        // AppKit's deltas are positive for up and left, in points for trackpads.
        let divisor = event.hasPreciseScrollingDeltas ? 16.0 : 1.0
        _ = ml_vnc_scroll(sessionID, -Double(event.scrollingDeltaX) / divisor, -Double(event.scrollingDeltaY) / divisor)
    }

    private func key(_ code: UInt16, _ characters: String, down: Bool) {
        guard sessionID != 0 else { return }
        _ = characters.withCString { ml_vnc_key(sessionID, code, $0, down ? 1 : 0) }
    }

    /// Rust decides which shortcuts stay on this Mac, as for Mac-to-Mac
    /// viewing: ⌃⌘F full screen, ⌃⌘D footer, ⌃⌘I, ⌃⌘Q lock, ⌥⌘Esc.
    static func keepsLocal(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let modifiers: UInt32 = (flags.contains(.shift) ? 1 : 0) | (flags.contains(.control) ? 2 : 0)
            | (flags.contains(.option) ? 4 : 0) | (flags.contains(.command) ? 8 : 0) | (flags.contains(.function) ? 32 : 0)
        return ml_input_keeps_local(event.keyCode, modifiers) != 0
    }

    override func keyDown(with event: NSEvent) {
        guard !Self.keepsLocal(event) else { return }
        key(event.keyCode, event.charactersIgnoringModifiers ?? "", down: true)
    }
    override func keyUp(with event: NSEvent) { key(event.keyCode, event.charactersIgnoringModifiers ?? "", down: false) }

    /// Command shortcuts go to the remote desktop (Command is its Super key).
    /// AppKit sends no key-up for them, so the key is pressed and released.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard sessionID != 0, window?.isKeyWindow == true, window?.firstResponder === self, !Self.keepsLocal(event) else {
            return super.performKeyEquivalent(with: event)
        }
        let characters = event.charactersIgnoringModifiers ?? ""
        key(event.keyCode, characters, down: true)
        key(event.keyCode, characters, down: false)
        return true
    }

    /// Left and right modifiers by their device-specific flag bits.
    private static let modifierBits: [UInt16: UInt] = [
        0x38: 0x02, 0x3C: 0x04, // left, right Shift
        0x3B: 0x01, 0x3E: 0x2000, // left, right Control
        0x3A: 0x20, 0x3D: 0x40, // left, right Option
        0x37: 0x08, 0x36: 0x10, // left, right Command
    ]

    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        if code == 0x39 { // Caps Lock toggles on each press.
            key(code, "", down: true); key(code, "", down: false)
            return
        }
        guard let bit = Self.modifierBits[code] else { return }
        key(code, "", down: event.modifierFlags.rawValue & bit != 0)
    }
}

/// The viewer window, laid out like the Mac-to-Mac viewer: the picture, a
/// diagnostic footer (⌃⌘D), full screen once the first picture arrives (⌃⌘F),
/// and an overlay when the session ends.
final class VNCViewerWindow: NSWindowController, NSWindowDelegate {
    let connectionID: String
    let view = VNCView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
    private var link: CADisplayLink?
    private let status = label("Connecting…", size: 11, color: .secondaryLabelColor)
    private let diagnosticBar = stack([], orientation: .horizontal, spacing: 12)
    /// Holds the bar, always below the picture as in the Mac-to-Mac viewer.
    /// The virtual screen on the Linux desktop is sized to the area above it.
    private let footer = NSVisualEffectView()
    private let exitFullScreen = NSButton(title: "Exit Full Screen", target: nil, action: nil)
    private var videoBottom: NSLayoutConstraint!
    static let footerHeight: CGFloat = 34
    private(set) var showsDiagnosticBar: Bool
    private let ended = NSVisualEffectView()
    private let endedTitle = label("Session ended", size: 17, weight: .semibold)
    private let endedReason = label("", size: 13, color: .secondaryLabelColor)
    private var desktopNote = ""
    private var summary = "Connecting…"
    private var statsTimer: Timer?
    private var lastStats = MLVncStats()
    private var lastStatsAt = Date()
    private var rates = ""
    private var sizedToPicture = false
    private(set) var isClosed = false
    var onClose: (() -> Void)?
    /// The server rejected the username or password (`message` from Rust).
    var onSignInRejected: ((String) -> Void)?
    var onEnded: ((String?) -> Void)?
    var onReconnect: (() -> Void)?
    /// ⌃⌘D changed the footer; the choice is shared with the Mac-to-Mac viewer.
    var onDiagnosticBarChange: ((Bool) -> Void)?

    init(name: String, connectionID: String, sessionID: UInt64, showsDiagnosticBar: Bool = true) {
        self.connectionID = connectionID
        self.showsDiagnosticBar = showsDiagnosticBar
        let window = MooringPrivacyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = name + " — Mooring"
        MooringAppearance.prepare(window)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 480, height: 320)
        window.acceptsMouseMovedEvents = true
        super.init(window: window)
        window.delegate = self
        view.sessionID = sessionID
        view.onFirstPicture = { [weak self] in self?.firstPicture() }
        let root = window.contentView!
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)

        let mark = NSImageView(image: MooringBrand.menuBarImage)
        mark.contentTintColor = MooringBrand.accent
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 18).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 18).isActive = true
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.maximumNumberOfLines = 1
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.toolTip = "The Linux desktop sends an update only when its screen changes. Moving your own pointer does not count."
        exitFullScreen.target = self; exitFullScreen.action = #selector(leaveFullScreen); exitFullScreen.bezelStyle = .inline
        exitFullScreen.toolTip = "Or press ⌃⌘F."
        exitFullScreen.isHidden = true
        let hideBar = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Hide diagnostic footer")!,
                               target: self, action: #selector(toggleDiagnosticBar(_:)))
        hideBar.bezelStyle = .inline
        hideBar.toolTip = "Hide diagnostic footer. Restore with ⌃⌘D or View → Diagnostic Footer."
        for item in [mark, status, NSView(), exitFullScreen, hideBar] { diagnosticBar.addArrangedSubview(item) }
        footer.material = .titlebar; footer.blendingMode = .withinWindow; footer.state = .active
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(diagnosticBar)
        root.addSubview(footer)
        videoBottom = view.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Self.footerHeight)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor), view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            view.topAnchor.constraint(equalTo: root.topAnchor), videoBottom,
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            diagnosticBar.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            diagnosticBar.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            diagnosticBar.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            diagnosticBar.heightAnchor.constraint(equalToConstant: 22),
        ])

        ended.material = .hudWindow; ended.blendingMode = .withinWindow; ended.state = .active
        ended.wantsLayer = true; ended.layer?.cornerRadius = 14
        ended.translatesAutoresizingMaskIntoConstraints = false; ended.isHidden = true
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        let reconnect = NSButton(title: "Reconnect", target: self, action: #selector(reconnect))
        reconnect.keyEquivalent = "\r"
        for button in [close, reconnect] { button.bezelStyle = .rounded }
        MooringAppearance.primary(reconnect)
        endedReason.alignment = .center
        let content = stack([endedTitle, endedReason, stack([close, reconnect], orientation: .horizontal, spacing: 10)], spacing: 12)
        content.alignment = .centerX
        ended.addSubview(content)
        root.addSubview(ended)
        NSLayoutConstraint.activate([
            ended.centerXAnchor.constraint(equalTo: view.centerXAnchor), ended.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ended.widthAnchor.constraint(equalToConstant: 380),
            content.leadingAnchor.constraint(equalTo: ended.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: ended.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: ended.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: ended.bottomAnchor, constant: -20),
            endedReason.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])

        layoutFooter()
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateRates() }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
        window.center()
        window.initialFirstResponder = view
        window.makeFirstResponder(view)
        render()
    }

    required init?(coder: NSCoder) { nil }

    /// A read-only lock-state title from the SSH desktop check.
    func showDesktop(_ title: String) {
        desktopNote = title
        render()
    }

    private func render() {
        let parts = [summary, rates, desktopNote].filter { !$0.isEmpty }
        status.stringValue = parts.joined(separator: " · ")
    }

    private func updateRates() {
        guard view.sessionID != 0 else { return }
        var now = MLVncStats()
        guard ml_vnc_stats(view.sessionID, &now) == 0 else { return }
        let seconds = max(Date().timeIntervalSince(lastStatsAt), 0.001)
        let updates = Double(now.updates &- lastStats.updates) / seconds
        let bytes = Double(now.bytes &- lastStats.bytes) / seconds
        lastStats = now; lastStatsAt = Date()
        let rate = bytes >= 1_000_000 ? String(format: "%.1f MB/s", bytes / 1_000_000) : String(format: "%.0f KB/s", bytes / 1_000)
        rates = String(format: "%.0f updates/s · ", updates) + rate
        render()
    }

    @objc private func tick() {
        guard view.sessionID != 0 else { return }
        var buffer = [CChar](repeating: 0, count: Int(ML_VNC_EVENT_CAPACITY))
        for _ in 0..<16 {
            var length = 0
            guard ml_vnc_poll_event(view.sessionID, &buffer, buffer.count, &length) == 0, length > 0 else { break }
            let data = Data(bytes: buffer, count: length)
            guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            handle(event)
            if view.sessionID == 0 { return }
        }
        view.refresh()
    }

    private func handle(_ event: [String: Any]) {
        switch event["event"] as? String {
        case "connected", "resized":
            let width = event["width"] as? Int ?? 0, height = event["height"] as? Int ?? 0
            summary = "\(width)×\(height) · RSA-AES through SSH"
            render()
            fitToPicture(width: width, height: height)
        case "bell":
            NSSound.beep()
        case "closed":
            let error = event["error"] as? [String: Any]
            let message = error?["message"] as? String
            end(message)
            if error?["kind"] as? String == "sign_in_rejected" {
                onSignInRejected?(message ?? "The sign-in was not accepted.")
            } else {
                onEnded?(message)
            }
        default:
            break
        }
    }

    /// Size the window to the desktop's shape: one remote pixel per screen
    /// pixel when that fits, otherwise as large as fits, and keep that shape
    /// while resizing.
    private func fitToPicture(width: Int, height: Int) {
        guard let window, width > 0, height > 0, !window.styleMask.contains(.fullScreen) else { return }
        let footer = showsDiagnosticBar ? Self.footerHeight : 0
        let scale = window.backingScaleFactor
        var size = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        if let visible = window.screen?.visibleFrame {
            let room = CGSize(width: visible.width * 0.92, height: visible.height * 0.92 - footer - 28)
            let fit = min(1, room.width / size.width, room.height / size.height)
            size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        }
        window.setContentSize(CGSize(width: size.width, height: size.height + footer))
        if !sizedToPicture { window.center(); sizedToPicture = true }
    }

    /// Keep the picture area at the desktop's shape while resizing.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let remote = view.remoteSize
        guard remote.width > 0, remote.height > 0, !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let footer = showsDiagnosticBar ? Self.footerHeight : 0
        let chrome = sender.frame.height - (sender.contentView?.frame.height ?? sender.frame.height)
        let width = frameSize.width
        let pictureHeight = (width * remote.height / remote.width).rounded()
        return NSSize(width: width, height: pictureHeight + footer + chrome)
    }

    private func firstPicture() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    func windowDidEnterFullScreen(_ notification: Notification) { exitFullScreen.isHidden = false }
    func windowDidExitFullScreen(_ notification: Notification) {
        exitFullScreen.isHidden = true
        let remote = view.remoteSize
        if remote.width > 0 { fitToPicture(width: Int(remote.width), height: Int(remote.height)) }
    }

    @objc private func leaveFullScreen() { window?.toggleFullScreen(nil) }

    /// View → Diagnostic Footer (⌃⌘D), shared with the Mac-to-Mac viewer.
    @objc func toggleDiagnosticBar(_ sender: Any?) {
        showsDiagnosticBar.toggle()
        layoutFooter()
        onDiagnosticBarChange?(showsDiagnosticBar)
    }

    private func layoutFooter() {
        videoBottom.constant = showsDiagnosticBar ? -Self.footerHeight : 0
        footer.isHidden = !showsDiagnosticBar
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    @objc private func closeWindow() { window?.performClose(nil) }

    @objc private func reconnect() {
        ended.isHidden = true
        onReconnect?()
    }

    /// Stop showing the session and say why, with Reconnect and Close.
    func end(_ message: String?) {
        let id = view.sessionID
        view.clear()
        link?.invalidate(); link = nil
        if id != 0 { DispatchQueue.global(qos: .userInitiated).async { _ = ml_vnc_close(id) } }
        endedReason.stringValue = message ?? "The connection to the Linux desktop has closed."
        ended.isHidden = false
        summary = "Disconnected"; rates = ""
        render()
    }

    func windowDidResignKey(_ notification: Notification) {
        if view.sessionID != 0 { _ = ml_vnc_release_all(view.sessionID) }
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        statsTimer?.invalidate(); statsTimer = nil
        let id = view.sessionID
        view.clear()
        link?.invalidate(); link = nil
        if id != 0 { DispatchQueue.global(qos: .userInitiated).async { _ = ml_vnc_close(id) } }
        onClose?()
    }
}

/// The sign-in prompt for a VNC server. Rust decides whether an attempt is
/// allowed; this only collects the two fields.
enum VNCSignIn {
    static func prompt(name: String, username: String, detail: String, completion: @escaping ((username: String, password: [UInt8])?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Sign in to \(name)"
        alert.informativeText = detail
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        let user = NSTextField(string: username)
        user.placeholderString = "Username"
        let secret = NSSecureTextField(string: "")
        secret.placeholderString = "Password"
        for field in [user, secret] { field.translatesAutoresizingMaskIntoConstraints = false; field.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        let fields = NSStackView(views: [user, secret])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = username.isEmpty ? user : secret
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        var password = Array(secret.stringValue.utf8)
        secret.stringValue = ""
        guard answer == .alertFirstButtonReturn, !password.isEmpty else {
            for index in password.indices { password[index] = 0 }
            completion(nil)
            return
        }
        completion((user.stringValue.trimmingCharacters(in: .whitespaces), password))
    }
}
