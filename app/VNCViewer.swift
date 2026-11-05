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
    /// Called when the remote desktop's size becomes known or changes.
    var onRemoteSize: (() -> Void)?
    private var shownPicture = false
    /// A second view showing part of the same picture (the row beside the
    /// camera housing). It is given each new surface; it never copies pixels.
    weak var mirror: VNCView?
    /// For a mirror: the view that owns the session and its surfaces.
    weak var source: VNCView?
    /// Show only these remote rows, filling the view exactly (their shape
    /// matches the view's); nil shows the whole picture, aspect-fit.
    var region: (top: Double, rows: Double)? { didSet { applyRegion() } }
    /// For a view in a window that never becomes key, such as the camera row.
    var tracksOutsideKeyWindow = false
    /// The remote desktop's size in pixels, once known.
    var remoteSize: CGSize {
        if let source { return source.remoteSize }
        return CGSize(width: surfaceSize.width, height: surfaceSize.height)
    }
    private var session: UInt64 { source?.sessionID ?? sessionID }
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
        let activity: NSTrackingArea.Options = tracksOutsideKeyWindow ? .activeAlways : .activeInKeyWindow
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, activity, .inVisibleRect], owner: self)
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
        applyRegion()
        onRemoteSize?()
        return true
    }

    /// The part of the picture shown, as a contents rectangle. Core Animation's
    /// unit space starts at the bottom left here, while remote rows count from
    /// the top.
    private func applyRegion() {
        let height = Double(remoteSize.height)
        guard let region, height > 0 else {
            layer?.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            layer?.contentsGravity = .resizeAspect
            return
        }
        layer?.contentsGravity = .resize
        layer?.contentsRect = CGRect(x: 0, y: (height - region.top - region.rows) / height, width: 1, height: region.rows / height)
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
            mirror?.layer?.contents = back
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
        mirror?.layer?.contents = nil
    }

    /// The event's position in remote desktop pixels: in the region shown, or
    /// given the aspect fit.
    private func remotePoint(_ event: NSEvent) -> (Double, Double) {
        let point = convert(event.locationInWindow, from: nil)
        let width = Double(max(remoteSize.width, 1)), height = Double(max(remoteSize.height, 1))
        if let region, bounds.width > 0, bounds.height > 0 {
            return (Double(point.x) / Double(bounds.width) * width,
                    region.top + (1 - Double(point.y) / Double(bounds.height)) * region.rows)
        }
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
        guard session != 0 else { return }
        let (x, y) = remotePoint(event)
        _ = ml_vnc_pointer(session, x, y, buttons)
    }

    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDown(with event: NSEvent) {
        if source == nil { window?.makeFirstResponder(self) }
        pointer(event)
    }
    override func mouseUp(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDown(with event: NSEvent) { pointer(event) }
    override func rightMouseUp(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDown(with event: NSEvent) { pointer(event) }
    override func otherMouseUp(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }

    override func scrollWheel(with event: NSEvent) {
        guard session != 0 else { return }
        pointer(event)
        // AppKit's deltas are positive for up and left, in points for trackpads.
        let divisor = event.hasPreciseScrollingDeltas ? 16.0 : 1.0
        _ = ml_vnc_scroll(session, -Double(event.scrollingDeltaX) / divisor, -Double(event.scrollingDeltaY) / divisor)
    }

    /// Keys forwarded by the system-shortcut tap, by event type.
    func forwardKey(_ event: NSEvent) {
        switch event.type {
        case .keyDown: keyDown(with: event)
        case .keyUp: keyUp(with: event)
        case .flagsChanged: flagsChanged(with: event)
        default: break
        }
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

/// The viewer window, laid out like the Mac-to-Mac viewer: the picture, its
/// diagnostic footer (⌃⌘D), full screen once the first picture arrives (⌃⌘F),
/// and an overlay when the session ends.
final class VNCViewerWindow: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let connectionID: String
    let view = VNCView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
    private var link: CADisplayLink?
    /// The Mac-to-Mac viewer's footer: below the picture, in a window and in
    /// full screen, until ⌃⌘D hides it. The virtual screen on the Linux
    /// desktop is sized to the area above it.
    let footer = ViewerFooter()
    /// The top of the picture, in the row beside this Mac's camera housing,
    /// as in the Mac-to-Mac viewer. Used when the virtual screen includes it.
    private let rowView = VNCView(frame: .zero)
    private lazy var cameraRow = NativeCameraRow(content: rowView)
    /// Set by the app: the Linux desktop was given a virtual screen that
    /// includes the row beside the camera housing.
    var extendsBesideCamera = false { didSet { layoutCameraRow() } }
    /// macOS acts on ⌘-Tab, ⌘-Space and other system shortcuts before Mooring
    /// sees them; with Accessibility allowed, this sends them to the desktop
    /// while the viewer is in front. ⌃⌘F, ⌃⌘D, ⌃⌘Q and ⌥⌘Esc stay here.
    private let systemKeys = NativeSystemKeyCapture()
    private(set) var showsDiagnosticBar: Bool
    /// From the start of entering full screen to the start of leaving it.
    /// AppKit resizes the window during the transition, so this does not
    /// wait for the style mask.
    private(set) var isFullScreen = false
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
    /// ⌃⌘D changed the footer; the app remembers it for Linux viewers.
    var onDiagnosticBarChange: ((Bool) -> Void)?
    var onAllowSystemKeys: (() -> Void)?

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
        view.onRemoteSize = { [weak self] in self?.layoutCameraRow() }
        view.mirror = rowView
        rowView.source = view
        rowView.tracksOutsideKeyWindow = true
        rowView.setAccessibilityLabel("Remote desktop, top bar")
        let root = window.contentView!
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        footer.status.toolTip = "The Linux desktop sends an update only when its screen changes. Moving your own pointer does not count."
        footer.hide.target = self; footer.hide.action = #selector(toggleDiagnosticBar(_:))
        footer.allowSystemKeys.target = self; footer.allowSystemKeys.action = #selector(allowKeys)
        footer.allowSystemKeys.toolTip = "Allow Mooring in Accessibility on this Mac to send ⌘-Tab, ⌘-Space and other system shortcuts to the Linux desktop."
        footer.allowSystemKeys.isHidden = NativeSystemKeyCapture.isPermitted
        footer.exitFullScreen.target = self; footer.exitFullScreen.action = #selector(leaveFullScreen)
        footer.install(in: root, below: view)
        footer.setVisible(showsDiagnosticBar)

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

        systemKeys.isCapturing = { [weak self] in
            guard let self, let window = self.window else { return false }
            return window.isKeyWindow && self.view.sessionID != 0
        }
        systemKeys.forward = { [weak self] event in self?.view.forwardKey(event) }
        // Releases the tap missed would leave keys held on the desktop.
        systemKeys.onInterrupted = { [weak self] in
            if let id = self?.view.sessionID, id != 0 { _ = ml_vnc_release_all(id) }
        }
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
        footer.status.stringValue = parts.joined(separator: " · ")
    }

    private func updateRates() {
        // Accessibility can be allowed mid-session; capture ⌘-Tab from then on,
        // and drop Allow ⌘-Tab… within a second, as the Mac-to-Mac viewer does.
        if let window, window.isKeyWindow, !systemKeys.isRunning { footer.allowSystemKeys.isHidden = systemKeys.start() }
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
        guard let window, width > 0, height > 0, !isFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        let footer = showsDiagnosticBar ? ViewerFooter.height : 0
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

    /// Keep the picture area at the desktop's shape while resizing in a
    /// window; full screen, including the transition, takes AppKit's size.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let remote = view.remoteSize
        guard remote.width > 0, remote.height > 0, !isFullScreen, !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let footer = showsDiagnosticBar ? ViewerFooter.height : 0
        let chrome = sender.frame.height - (sender.contentView?.frame.height ?? sender.frame.height)
        let width = frameSize.width
        let pictureHeight = (width * remote.height / remote.width).rounded()
        return NSSize(width: width, height: pictureHeight + footer + chrome)
    }

    private func firstPicture() {
        guard let window, !isFullScreen, !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    /// As in a Mac-to-Mac viewer that controls the other Mac (a Linux viewer
    /// always sends input): full screen hides this Mac's menu bar and Dock,
    /// so the top edge reaches the desktop's top bar instead of sliding down
    /// this Mac's menu bar and the viewer's title bar, and the bottom edge
    /// reaches the footer without the Dock. ⌃⌘F, Exit Full Screen in the
    /// footer and a swipe between Spaces lead back.
    /// As in the Mac-to-Mac viewer: while ⌘ shortcuts go to the desktop
    /// (Accessibility allowed), this Mac's menu bar and Dock stay hidden in
    /// full screen; otherwise they appear at the screen's edges as usual.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        NativeSystemKeyCapture.isPermitted ? [.fullScreen, .hideDock, .hideMenuBar] : proposedOptions
    }
    func windowWillEnterFullScreen(_ notification: Notification) { isFullScreen = true }
    func windowDidEnterFullScreen(_ notification: Notification) {
        footer.exitFullScreen.isHidden = false
        layoutCameraRow()
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { isFullScreen = false; hideCameraRow() }
    func windowWillExitFullScreen(_ notification: Notification) { isFullScreen = false; hideCameraRow() }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { isFullScreen = true; layoutCameraRow() }
    func windowDidResize(_ notification: Notification) { layoutCameraRow() }
    func windowDidChangeScreen(_ notification: Notification) { layoutCameraRow() }
    func windowDidExitFullScreen(_ notification: Notification) {
        footer.exitFullScreen.isHidden = true
        let remote = view.remoteSize
        if remote.width > 0 { fitToPicture(width: Int(remote.width), height: Int(remote.height)) }
    }

    @objc private func leaveFullScreen() { window?.toggleFullScreen(nil) }

    /// View → Diagnostic Footer (⌃⌘D), shared with the Mac-to-Mac viewer.
    @objc func toggleDiagnosticBar(_ sender: Any?) {
        setDiagnosticBarVisible(!showsDiagnosticBar)
        onDiagnosticBarChange?(showsDiagnosticBar)
    }

    func setDiagnosticBarVisible(_ visible: Bool) {
        showsDiagnosticBar = visible
        footer.setVisible(visible)
        // The footer changes the picture's height, and with it whether, and
        // where, the picture is split with the row beside the camera.
        layoutCameraRow()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleDiagnosticBar(_:)) { item.state = showsDiagnosticBar ? .on : .off }
        return !isClosed && window?.attachedSheet == nil
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

    func windowDidBecomeKey(_ notification: Notification) {
        footer.allowSystemKeys.isHidden = systemKeys.start()
    }

    func windowDidResignKey(_ notification: Notification) {
        systemKeys.stop()
        if view.sessionID != 0 { _ = ml_vnc_release_all(view.sessionID) }
    }

    @objc private func allowKeys() { onAllowSystemKeys?() }

    /// In full screen on a Mac with a camera housing, show the top of the
    /// picture in the row beside it, when the virtual screen was sized to
    /// include that row. Otherwise the whole picture fits below it.
    private func layoutCameraRow() {
        guard extendsBesideCamera, isFullScreen, !isClosed, let window,
              let screen = window.screen, NativeCameraRow.housing(on: screen) != nil else {
            hideCameraRow(); return
        }
        let rowHeight = screen.frame.maxY - window.frame.maxY
        let remote = view.remoteSize
        guard let rowRows = Self.cameraRowRows(remoteHeight: remote.height, scale: screen.backingScaleFactor,
                                               rowHeight: rowHeight, below: view.bounds.height) else {
            hideCameraRow(); return
        }
        rowView.region = (0, rowRows)
        view.region = (rowRows, Double(remote.height) - rowRows)
        cameraRow.setFrame(NSRect(x: screen.frame.minX, y: window.frame.maxY, width: screen.frame.width, height: rowHeight), display: false)
        if cameraRow.parent == nil { window.addChildWindow(cameraRow, ordered: .above) }
        // A child takes its parent's level when added; raise it after.
        cameraRow.level = .statusBar
        cameraRow.orderFront(nil)
    }

    /// The desktop's rows shown in the row beside the camera housing: when a
    /// desktop `remoteHeight` pixels tall at `scale` fills that row and the
    /// picture area below it (both in points) to within 2 points. Otherwise
    /// nil, and the whole desktop fits below the housing.
    static func cameraRowRows(remoteHeight: CGFloat, scale: CGFloat, rowHeight: CGFloat, below: CGFloat) -> Double? {
        guard rowHeight >= 1, remoteHeight > 0, below > 0, scale > 0,
              abs(remoteHeight / scale - (below + rowHeight)) < 2 else { return nil }
        return Double(remoteHeight) * Double(rowHeight / (below + rowHeight))
    }

    /// The virtual screen to ask the Linux desktop for, in pixels, so it fills
    /// the picture area in full screen on a screen `size` points at `scale`:
    /// the whole height when the picture uses the row beside the camera
    /// housing, otherwise the height below `safeTop`; less the footer when it
    /// is shown. Rust checks the size again.
    static func virtualScreen(size: CGSize, safeTop: CGFloat, scale: CGFloat, besideCamera: Bool,
                              showsFooter: Bool) -> (width: Int, height: Int) {
        let top = besideCamera ? 0 : safeTop
        let footer = showsFooter ? ViewerFooter.height : 0
        return (Int((size.width * scale).rounded()) & ~1, Int(((size.height - top - footer) * scale).rounded()) & ~1)
    }

    private func hideCameraRow() {
        view.region = nil
        rowView.region = nil
        cameraRow.parent?.removeChildWindow(cameraRow)
        cameraRow.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        systemKeys.stop()
        hideCameraRow()
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
