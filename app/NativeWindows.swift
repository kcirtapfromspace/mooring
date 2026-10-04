import AppKit
import MetalKit

final class NativeShareWindow: NSWindowController, NSWindowDelegate {
    var onToggle: (() -> Void)?
    var onCopy: (() -> Void)?
    var onReset: (() -> Void)?
    var onControlPermission: (() -> Void)?
    var onDiagnostics: (() -> Void)?
    var onAutomaticChange: ((Bool) -> Void)?
    var onClipboardChange: ((Bool) -> Void)?
    let status = label("Sharing is off", size: 14, weight: .medium)
    let detail = label("Start sharing, then copy the pairing code to MacLink on your other Mac.", color: .secondaryLabelColor)
    let toggle = NSButton(title: "Start Sharing", target: nil, action: nil)
    let copy = NSButton(title: "Copy Pairing Code", target: nil, action: nil)
    let control = NSButton(title: "Enable Keyboard & Mouse…", target: nil, action: nil)
    private let controlNote = label("Allow Accessibility on this Mac to enable remote control.", size: 12, color: .secondaryLabelColor)
    let automatic = NSButton(checkboxWithTitle: "Share this Mac automatically", target: nil, action: nil)
    let clipboard = NSButton(checkboxWithTitle: "Share clipboard with the connected Mac", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Share This Mac"
        MacLinkAppearance.prepare(window)
        window.contentMinSize = NSSize(width: 540, height: 460)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let heading = MacLinkAppearance.header("Share this Mac", subtitle: "Your workspace, on your other Mac.")
        let note = label("Pairing allows viewing and, when enabled, keyboard and mouse control. Keep the code private. Sharing continues after you close this window; stop it here or from the menu bar.", size: 12, color: .secondaryLabelColor)
        let automaticNote = label("Starts sharing when MacLink opens and resumes after sleep or lock. To share after you log in, turn on Launch MacLink at login in Settings.", size: 12, color: .secondaryLabelColor)
        let reset = NSButton(title: "Reset Pairing", target: self, action: #selector(resetPairing))
        let diagnostics = NSButton(title: "Save Diagnostics…", target: self, action: #selector(saveDiagnostics))
        toggle.target = self; toggle.action = #selector(toggleSharing); toggle.keyEquivalent = "\r"
        copy.target = self; copy.action = #selector(copyCode); copy.isEnabled = false
        control.target = self; control.action = #selector(enableControl)
        automatic.target = self; automatic.action = #selector(changeAutomatic)
        clipboard.target = self; clipboard.action = #selector(changeClipboard)
        clipboard.toolTip = "Copy on one Mac and paste on the other while connected. Items password managers mark as private are never shared."
        for button in [toggle, copy, control, reset, diagnostics] { button.bezelStyle = .rounded }
        MacLinkAppearance.primary(toggle)
        let actions = stack([toggle, copy], orientation: .horizontal, spacing: 10)
        let extras = stack([reset, NSView(), diagnostics], orientation: .horizontal, spacing: 10)
        let state = stack([status, detail, actions], spacing: 12)
        detail.widthAnchor.constraint(equalTo: state.widthAnchor).isActive = true
        let preferences = stack([MacLinkAppearance.sectionTitle("Sharing preferences", symbol: "slider.horizontal.3"),
                                 controlNote, control, stack([automatic, automaticNote], spacing: 4), clipboard], spacing: 12)
        preferences.detachesHiddenViews = true
        controlNote.widthAnchor.constraint(equalTo: preferences.widthAnchor).isActive = true
        automaticNote.widthAnchor.constraint(equalTo: preferences.widthAnchor).isActive = true
        let body = stack([heading, MacLinkAppearance.surface(state), preferences, note, extras], spacing: 24)
        MacLinkAppearance.scrollBody(body, in: window.contentView!)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func showControlPermission(_ allowed: Bool) {
        control.isHidden = allowed
        controlNote.stringValue = allowed ? "Keyboard and mouse control is enabled." : "Allow Accessibility on this Mac to enable remote control."
    }
    @objc private func toggleSharing() { onToggle?() }
    @objc private func changeAutomatic() { onAutomaticChange?(automatic.state == .on) }
    @objc private func changeClipboard() { onClipboardChange?(clipboard.state == .on) }
    @objc private func copyCode() { onCopy?() }
    @objc private func resetPairing() { onReset?() }
    @objc private func enableControl() { onControlPermission?() }
    @objc private func saveDiagnostics() { onDiagnostics?() }
}

final class NativePairWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    var onConnect: ((String, String) -> Void)?
    let code = NSSecureTextField(string: "")
    let address = NSTextField(string: "")
    let error = label("", size: 12, color: .systemRed)
    let connect = NSButton(title: "Pair & Connect", target: nil, action: nil)
    private let options = NSButton(title: "Address override", target: nil, action: nil)
    private var addressForm: NSStackView!
    private var busy = false
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Connect with MacLink"
        MacLinkAppearance.prepare(window)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let heading = MacLinkAppearance.header("Pair a Mac", subtitle: "Pair once. Connect anytime.")
        let note = label("On your other Mac, open MacLink → Share This Mac → Start Sharing, then copy its pairing code here.", color: .secondaryLabelColor)
        code.placeholderString = "Paste pairing code"; code.setAccessibilityLabel("Pairing code")
        address.placeholderString = "Optional — the code lists the Mac's addresses"; address.setAccessibilityLabel("Mac address override")
        code.controlSize = .large; address.controlSize = .large
        code.delegate = self; address.delegate = self
        let form = stack([label("Pairing code", size: 12, weight: .medium), code], spacing: 6)
        code.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        addressForm = stack([label("Address", size: 12, weight: .medium), address], spacing: 6)
        address.widthAnchor.constraint(equalTo: addressForm.widthAnchor).isActive = true
        addressForm.isHidden = true
        options.bezelStyle = .inline; options.setButtonType(.onOff)
        options.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        options.imagePosition = .imageLeading
        options.target = self; options.action = #selector(toggleOptions)
        options.toolTip = "Use a different address, such as the sharing Mac’s VPN address."
        connect.target = self; connect.action = #selector(pair); connect.keyEquivalent = "\r"
        MacLinkAppearance.primary(connect)
        connect.isEnabled = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPairing))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let actions = stack([NSView(), cancel, connect], orientation: .horizontal, spacing: 8)
        error.maximumNumberOfLines = 3
        error.lineBreakMode = .byTruncatingTail
        let body = stack([heading, note, form, options, addressForm, error, actions], spacing: 18)
        body.detachesHiddenViews = true
        let root = window.contentView!; root.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 24)
        ])
        for view in [heading, note, form, addressForm!, error, actions] { view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        window.initialFirstResponder = code
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func pair() {
        guard !busy, !code.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onConnect?(code.stringValue, address.stringValue)
    }
    @objc private func cancelPairing() { window?.performClose(nil) }
    @objc private func toggleOptions() {
        let expanded = options.state == .on
        addressForm.isHidden = !expanded
        options.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        window?.setContentSize(NSSize(width: 560, height: expanded ? 460 : 380))
    }
    func controlTextDidChange(_ obj: Notification) {
        connect.isEnabled = !busy && !code.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        error.stringValue = ""
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func setBusy(_ busy: Bool) {
        self.busy = busy
        connect.isEnabled = !busy && !code.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        code.isEnabled = !busy; address.isEnabled = !busy; options.isEnabled = !busy
        connect.title = busy ? "Connecting…" : "Pair & Connect"
    }
}

final class NativeRemoteView: NativeVideoView {
    var onInput: ((NSEvent) -> Void)?
    var onReleaseInput: (() -> Void)?
    /// Hides this Mac's pointer over the video when the remote pointer is in it.
    var hidesLocalCursor = false { didSet { if hidesLocalCursor != oldValue { window?.invalidateCursorRects(for: self) } } }
    /// While controlling, the sharing Mac's own pointer shape, such as an I-beam over text.
    var remoteCursor: NSCursor? { didSet { window?.invalidateCursorRects(for: self) } }
    /// Command chords go to the remote Mac only while it accepts control; in a
    /// view-only session ⌘W and the menu shortcuts act on this Mac.
    var forwardsCommandKeys = false
    private static let invisibleCursor = NSCursor(image: NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true },
                                                  hotSpot: .zero)
    private var tracking: NSTrackingArea?
    private var commandKeyUps: NativeCommandKeyUpMonitor?
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {
        if hidesLocalCursor { addCursorRect(bounds, cursor: Self.invisibleCursor) }
        else if let remoteCursor { addCursorRect(bounds, cursor: remoteCursor) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        commandKeyUps?.stop()
        commandKeyUps = window == nil ? nil : NativeCommandKeyUpMonitor(view: self) { [weak self] in self?.onInput?($0) }
    }
    override func resignFirstResponder() -> Bool { onReleaseInput?(); return super.resignFirstResponder() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func keyDown(with event: NSEvent) { onInput?(event) }
    override func keyUp(with event: NSEvent) { onInput?(event) }
    override func flagsChanged(with event: NSEvent) { onInput?(event) }
    override func mouseMoved(with event: NSEvent) { onInput?(event) }
    override func mouseDragged(with event: NSEvent) { onInput?(event) }
    override func rightMouseDragged(with event: NSEvent) { onInput?(event) }
    override func otherMouseDragged(with event: NSEvent) { onInput?(event) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onInput?(event) }
    override func mouseUp(with event: NSEvent) { onInput?(event) }
    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onInput?(event) }
    override func rightMouseUp(with event: NSEvent) { onInput?(event) }
    override func otherMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onInput?(event) }
    override func otherMouseUp(with event: NSEvent) { onInput?(event) }
    override func scrollWheel(with event: NSEvent) { onInput?(event) }
    override func magnify(with event: NSEvent) { onInput?(event) }
    override func rotate(with event: NSEvent) { onInput?(event) }
    override func smartMagnify(with event: NSEvent) { onInput?(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Force Quit, Lock Screen and full-screen chords stay on this Mac; other
        // Command chords belong to the remote desktop while this view has focus.
        if event.type == .keyDown,
           NativeSystemKeyCapture.keepsLocal(keyCode: event.keyCode, modifiers: .from(event.modifierFlags)) { return false }
        guard forwardsCommandKeys, window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.command) else { return false }
        onInput?(event); return true
    }
}

final class NativeViewerWindow: NSWindowController, NSWindowDelegate {
    let video = NativeRemoteView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    let status = label("Connecting…", size: 12, color: .secondaryLabelColor)
    /// The paired Mac this window shows; reconnecting reuses the window.
    let peerID: String
    var onClose: (() -> Void)?
    var onReleaseInput: (() -> Void)?
    var onDiagnostics: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onCancelReconnect: (() -> Void)?
    var onAllowSystemKeys: (() -> Void)?
    var onVersionAction: (() -> Void)?
    /// Set once the window closes; a closed window is never reused.
    private(set) var isClosed = false
    /// Full screen is entered for the first picture only, so a reconnect keeps
    /// the user's own choice.
    var hasShownVideo = false
    private let ended = NSVisualEffectView()
    private let endedTitle = label("Session ended", size: 17, weight: .semibold)
    private let endedReason = label("", size: 13, color: .secondaryLabelColor)
    private let reconnectButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let allowSystemKeys = NSButton(title: "Allow ⌘-Tab…", target: nil, action: nil)
    /// When the two Macs run different MacLink versions: what that means and,
    /// when there is one, the next step.
    private let versionNotice = NSButton(title: "", target: nil, action: nil)
    private let exitFullScreen = NSButton(title: "Exit Full Screen", target: nil, action: nil)
    init(name: String, peerID: String) {
        self.peerID = peerID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = name + " — MacLink"
        MacLinkAppearance.prepare(window)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 540, height: 360)
        super.init(window: window)
        window.delegate = self
        let root = window.contentView!
        video.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(video)
        let diagnostics = NSButton(title: "Diagnostics…", target: self, action: #selector(saveDiagnostics))
        diagnostics.bezelStyle = .inline
        allowSystemKeys.target = self; allowSystemKeys.action = #selector(allowKeys); allowSystemKeys.bezelStyle = .inline
        allowSystemKeys.toolTip = "Allow MacLink in Accessibility on this Mac to send ⌘-Tab and other system shortcuts to the remote Mac."
        allowSystemKeys.isHidden = true
        versionNotice.target = self; versionNotice.action = #selector(versionAction); versionNotice.bezelStyle = .inline
        versionNotice.isHidden = true
        exitFullScreen.target = self; exitFullScreen.action = #selector(leaveFullScreen); exitFullScreen.bezelStyle = .inline
        exitFullScreen.toolTip = "Or press ⌃⌘F. Swiping between Spaces also shows this Mac without leaving full screen."
        exitFullScreen.isHidden = true
        let mark = NSImageView(image: MacLinkBrand.menuBarImage)
        mark.contentTintColor = MacLinkBrand.accent
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 18).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 18).isActive = true
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.maximumNumberOfLines = 1
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = stack([mark, status, NSView(), versionNotice, allowSystemKeys, exitFullScreen, diagnostics], orientation: .horizontal, spacing: 12)
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: root.leadingAnchor), video.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            video.topAnchor.constraint(equalTo: root.topAnchor), video.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -6),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6), bar.heightAnchor.constraint(equalToConstant: 22)
        ])
        window.initialFirstResponder = video
        window.acceptsMouseMovedEvents = true
        status.toolTip = "The sharing Mac sends a frame only when its screen changes, up to 60 per second. Moving your own pointer does not count."

        // Shown over the cleared video when a session ends, so the reason is not
        // lost in a full-screen black window.
        ended.material = .hudWindow; ended.blendingMode = .withinWindow; ended.state = .active
        ended.wantsLayer = true; ended.layer?.cornerRadius = 14
        ended.translatesAutoresizingMaskIntoConstraints = false; ended.isHidden = true
        reconnectButton.target = self; reconnectButton.action = #selector(reconnect); reconnectButton.keyEquivalent = "\r"
        closeButton.target = self; closeButton.action = #selector(closeWindow)
        cancelButton.target = self; cancelButton.action = #selector(cancelReconnect)
        for button in [reconnectButton, closeButton, cancelButton] { button.bezelStyle = .rounded }
        MacLinkAppearance.primary(reconnectButton)
        endedReason.alignment = .center
        let content = stack([endedTitle, endedReason,
                             stack([closeButton, cancelButton, reconnectButton], orientation: .horizontal, spacing: 10)], spacing: 12)
        content.alignment = .centerX
        ended.addSubview(content)
        root.addSubview(ended)
        NSLayoutConstraint.activate([
            ended.centerXAnchor.constraint(equalTo: video.centerXAnchor), ended.centerYAnchor.constraint(equalTo: video.centerYAnchor),
            ended.widthAnchor.constraint(equalToConstant: 380),
            content.leadingAnchor.constraint(equalTo: ended.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: ended.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: ended.topAnchor, constant: 22),
            content.bottomAnchor.constraint(equalTo: ended.bottomAnchor, constant: -20),
            endedReason.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func showEnded(reason: String) {
        showOverlay(title: "Session ended", reason: reason, reconnecting: false)
    }
    /// Shown between automatic attempts; Cancel stops them.
    func showReconnecting(reason: String, attempt: Int, of attempts: Int) {
        showOverlay(title: "Reconnecting…", reason: "\(reason)\nAttempt \(attempt) of \(attempts).", reconnecting: true)
    }
    /// A connect started from this window; Cancel stops it.
    func showConnecting() { showOverlay(title: "Connecting…", reason: endedReason.stringValue, reconnecting: true) }
    func hideOverlay() { ended.isHidden = true }
    var isReconnecting: Bool { !ended.isHidden && !cancelButton.isHidden }
    func setSystemKeysAllowed(_ allowed: Bool) { allowSystemKeys.isHidden = allowed }
    /// nil hides the notice; a disabled notice is information only.
    func setVersionNotice(_ text: String?, enabled: Bool = false) {
        versionNotice.isHidden = text == nil
        versionNotice.title = text ?? ""
        versionNotice.isEnabled = enabled
    }
    private func showOverlay(title: String, reason: String, reconnecting: Bool) {
        endedTitle.stringValue = title; endedReason.stringValue = reason
        cancelButton.isHidden = !reconnecting
        reconnectButton.isHidden = reconnecting; closeButton.isHidden = reconnecting
        ended.isHidden = false
    }
    @objc private func reconnect() { onReconnect?() }
    @objc private func cancelReconnect() { onCancelReconnect?() }
    @objc private func allowKeys() { onAllowSystemKeys?() }
    @objc private func versionAction() { onVersionAction?() }
    @objc private func closeWindow() { window?.performClose(nil) }
    @objc private func leaveFullScreen() { window?.toggleFullScreen(nil) }
    /// While this Mac controls the remote one, full screen hides this Mac's menu
    /// bar and Dock, so the top edge reaches the remote menu bar instead of
    /// revealing this window's title bar. Decided on entering full screen; ⌃⌘F
    /// and Exit Full Screen in the status bar leave it.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        video.forwardsCommandKeys ? [.fullScreen, .hideDock, .hideMenuBar] : proposedOptions
    }
    func windowDidEnterFullScreen(_ notification: Notification) { exitFullScreen.isHidden = false }
    func windowDidExitFullScreen(_ notification: Notification) { exitFullScreen.isHidden = true }
    func windowWillClose(_ notification: Notification) { isClosed = true; onClose?() }
    func windowDidResignKey(_ notification: Notification) { onReleaseInput?() }
    func windowDidMiniaturize(_ notification: Notification) { onReleaseInput?() }
    @objc private func saveDiagnostics() { onDiagnostics?() }
}
