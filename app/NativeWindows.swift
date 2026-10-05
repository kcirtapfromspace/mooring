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
    let detail = label("Start sharing. Copy a code to your other Mac.", color: .secondaryLabelColor)
    let toggle = NSButton(title: "Start sharing", target: nil, action: nil)
    let copy = NSButton(title: "Copy code", target: nil, action: nil)
    let control = NSButton(title: "Allow control…", target: nil, action: nil)
    private let controlNote = label("Allow Accessibility for remote control.", size: 12, color: .secondaryLabelColor)
    let automatic = NSButton(checkboxWithTitle: "Share this Mac automatically", target: nil, action: nil)
    let clipboard = NSButton(checkboxWithTitle: "Share clipboard with the connected Mac", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Share this Mac"
        MacLinkAppearance.prepare(window)
        window.contentMinSize = NSSize(width: 540, height: 460)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let heading = MacLinkAppearance.header("Share this Mac", subtitle: "Your workspace, on your other Mac.")
        let note = label("A code grants access. Keep it private. Sharing stays on when this window closes.", size: 12, color: .secondaryLabelColor)
        let automaticNote = label("Starts with Mooring. Resumes when this Mac wakes and unlocks.", size: 12, color: .secondaryLabelColor)
        let reset = NSButton(title: "Reset pairing", target: self, action: #selector(resetPairing))
        let diagnostics = NSButton(title: "Save diagnostics…", target: self, action: #selector(saveDiagnostics))
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
        let preferences = stack([MacLinkAppearance.sectionTitle("Access", symbol: "slider.horizontal.3"),
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
        controlNote.stringValue = allowed ? "Remote control allowed." : "Allow Accessibility for remote control."
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
    let connect = NSButton(title: "Pair & connect", target: nil, action: nil)
    private let options = NSButton(title: "Address override", target: nil, action: nil)
    private var addressForm: NSStackView!
    private var busy = false
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair a Mac"
        MacLinkAppearance.prepare(window)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let heading = MacLinkAppearance.header("Pair a Mac", subtitle: "Pair once. Connect anytime.")
        let note = label("On your other Mac: Mooring → Share this Mac → Start sharing. Copy its code here.", color: .secondaryLabelColor)
        code.placeholderString = "Paste pairing code"; code.setAccessibilityLabel("Pairing code")
        address.placeholderString = "Optional address"; address.setAccessibilityLabel("Mac address override")
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
        connect.title = busy ? "Connecting…" : "Pair & connect"
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
    override func keyDown(with event: NSEvent) {
        if NativeSystemKeyCapture.keepsLocal(keyCode: event.keyCode, modifiers: .from(event.modifierFlags)) { super.keyDown(with: event) }
        else { onInput?(event) }
    }
    override func keyUp(with event: NSEvent) {
        guard !NativeSystemKeyCapture.keepsLocal(keyCode: event.keyCode, modifiers: .from(event.modifierFlags)) else { return }
        onInput?(event)
    }
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
        // Escape hatches and diagnostic toggles stay on this Mac; other Command
        // chords belong to the remote desktop while this view has focus.
        if event.type == .keyDown,
           NativeSystemKeyCapture.keepsLocal(keyCode: event.keyCode, modifiers: .from(event.modifierFlags)) { return false }
        guard forwardsCommandKeys, window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.command) else { return false }
        onInput?(event); return true
    }
}

/// A bounded, scrollable overlay: it never changes the shared display size.
final class NativeViewerStatsView: NSVisualEffectView {
    var onClose: (() -> Void)?
    var onSave: (() -> Void)?
    private let notice = label("Connecting…", size: 11, color: .secondaryLabelColor)
    private var values: [NSTextField] = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 12
        setAccessibilityIdentifier("MacLink.StatsForNerds")
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close stats")!, target: self, action: #selector(closeStats))
        close.bezelStyle = .inline; close.toolTip = "Close stats (⌃⌘I)"
        let heading = stack([label("Stats for nerds", size: 15, weight: .semibold), NSView(), close], orientation: .horizontal, spacing: 8)
        let top = stack([heading, notice], spacing: 3)
        addSubview(top)

        let body = stack([], spacing: 14)
        for section in NativeViewerDiagnostics().sections {
            let rows = stack([], spacing: 5)
            for row in section.rows {
                let name = label(row.name, size: 11, color: .secondaryLabelColor)
                name.widthAnchor.constraint(equalToConstant: 138).isActive = true
                let value = label(row.value, size: 11)
                value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                value.preferredMaxLayoutWidth = 240
                value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                value.setAccessibilityLabel(row.name)
                values.append(value)
                let line = stack([name, value], orientation: .horizontal, spacing: 10)
                rows.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            let group = stack([label(section.title, size: 11, weight: .semibold), rows], spacing: 7)
            rows.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            body.addArrangedSubview(group)
        }
        let scrollRoot = NSView(); scrollRoot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollRoot)
        MacLinkAppearance.scrollBody(body, in: scrollRoot)
        let note = label("Local rates cover a rolling second; host stats arrive once a second. Recovery counts cover this session. Still screens send fewer frames. Screen → display uses synchronized clocks, not input latency. — means unavailable. Audio gaps are unsent packets, not measured network loss.", size: 10, color: .secondaryLabelColor)
        note.preferredMaxLayoutWidth = 404
        let save = NSButton(title: "Save diagnostics…", target: self, action: #selector(saveStats))
        save.bezelStyle = .rounded; save.controlSize = .small
        let bottom = stack([note, save], spacing: 8)
        addSubview(bottom)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            top.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            heading.widthAnchor.constraint(equalTo: top.widthAnchor),
            notice.widthAnchor.constraint(equalTo: top.widthAnchor),
            scrollRoot.leadingAnchor.constraint(equalTo: leadingAnchor), scrollRoot.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollRoot.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 4),
            scrollRoot.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            note.widthAnchor.constraint(equalTo: bottom.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ snapshot: NativeViewerDiagnostics) {
        notice.stringValue = snapshot.hostNotice
        for (field, row) in zip(values, snapshot.sections.flatMap(\.rows)) {
            field.stringValue = row.value
            field.setAccessibilityLabel("\(row.name): \(row.value)")
        }
    }
    @objc private func closeStats() { onClose?() }
    @objc private func saveStats() { onSave?() }
}

final class NativeViewerWindow: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
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
    var onDiagnosticBarChange: ((Bool) -> Void)?
    var onViewportChange: (() -> Void)?
    private(set) var showsDiagnosticBar = true
    private(set) var showsStatsForNerds = false
    private let diagnosticBar = stack([], orientation: .horizontal, spacing: 12)
    private let statsButton = NSButton(title: "Stats for nerds", target: nil, action: nil)
    private let statsView = NativeViewerStatsView()
    private var latestDiagnostics = NativeViewerDiagnostics()
    private var videoBottom: NSLayoutConstraint!
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
    init(name: String, peerID: String, showsDiagnosticBar: Bool = true) {
        self.peerID = peerID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = name + " — Mooring"
        MacLinkAppearance.prepare(window)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 540, height: 360)
        super.init(window: window)
        window.delegate = self
        let root = window.contentView!
        video.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(video)
        statsButton.target = self; statsButton.action = #selector(toggleStatsForNerds(_:)); statsButton.bezelStyle = .inline
        statsButton.toolTip = "Live stream details (⌃⌘I). Also available from the View menu when the footer is hidden."
        let hideBar = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Hide diagnostic footer")!, target: self, action: #selector(toggleDiagnosticBar(_:)))
        hideBar.bezelStyle = .inline
        hideBar.toolTip = "Hide diagnostic footer. Restore with ⌃⌘D or View → Diagnostic Footer."
        allowSystemKeys.target = self; allowSystemKeys.action = #selector(allowKeys); allowSystemKeys.bezelStyle = .inline
        allowSystemKeys.toolTip = "Allow Mooring in Accessibility on this Mac to send ⌘-Tab and other system shortcuts to the remote Mac."
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
        let bar = diagnosticBar
        for view in [mark, status, NSView(), versionNotice, allowSystemKeys, exitFullScreen, statsButton, hideBar] { bar.addArrangedSubview(view) }
        root.addSubview(bar)
        videoBottom = video.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: root.leadingAnchor), video.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            video.topAnchor.constraint(equalTo: root.topAnchor), videoBottom,
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6), bar.heightAnchor.constraint(equalToConstant: 22)
        ])
        setDiagnosticBarVisible(showsDiagnosticBar)
        statsView.isHidden = true
        statsView.onClose = { [weak self] in self?.toggleStatsForNerds(nil) }
        statsView.onSave = { [weak self] in self?.saveDiagnostics(nil) }
        root.addSubview(statsView)
        let preferredWidth = statsView.widthAnchor.constraint(equalToConstant: 440)
        let preferredHeight = statsView.heightAnchor.constraint(equalToConstant: 560)
        preferredWidth.priority = .defaultHigh; preferredHeight.priority = NSLayoutConstraint.Priority(1)
        NSLayoutConstraint.activate([
            statsView.topAnchor.constraint(equalTo: video.topAnchor, constant: 16),
            statsView.trailingAnchor.constraint(equalTo: video.trailingAnchor, constant: -16),
            statsView.widthAnchor.constraint(lessThanOrEqualTo: video.widthAnchor, constant: -32),
            statsView.heightAnchor.constraint(lessThanOrEqualTo: video.heightAnchor, constant: -32),
            preferredWidth, preferredHeight
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
    func setDiagnosticBarVisible(_ visible: Bool) {
        showsDiagnosticBar = visible
        diagnosticBar.isHidden = !visible
        videoBottom.constant = visible ? -34 : 0
    }
    func updateDiagnostics(_ snapshot: NativeViewerDiagnostics) {
        latestDiagnostics = snapshot
        if showsStatsForNerds { statsView.update(snapshot) }
    }
    @objc func toggleDiagnosticBar(_ sender: Any?) {
        onReleaseInput?()
        setDiagnosticBarVisible(!showsDiagnosticBar)
        onDiagnosticBarChange?(showsDiagnosticBar)
    }
    @objc func toggleStatsForNerds(_ sender: Any?) {
        onReleaseInput?()
        showsStatsForNerds.toggle()
        statsView.isHidden = !showsStatsForNerds
        statsButton.state = showsStatsForNerds ? .on : .off
        if showsStatsForNerds { statsView.update(latestDiagnostics) }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleDiagnosticBar(_:)) { item.state = showsDiagnosticBar ? .on : .off }
        if item.action == #selector(toggleStatsForNerds(_:)) { item.state = showsStatsForNerds ? .on : .off }
        return !isClosed && window?.attachedSheet == nil
    }
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
    func windowDidResize(_ notification: Notification) { onViewportChange?() }
    func windowWillClose(_ notification: Notification) { isClosed = true; onClose?() }
    func windowDidResignKey(_ notification: Notification) { onReleaseInput?() }
    func windowDidMiniaturize(_ notification: Notification) { onReleaseInput?() }
    @objc func saveDiagnostics(_ sender: Any?) { onReleaseInput?(); onDiagnostics?() }
}
