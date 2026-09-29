import AppKit
import MetalKit

final class NativeShareWindow: NSWindowController, NSWindowDelegate {
    var onToggle: (() -> Void)?
    var onCopy: (() -> Void)?
    var onReset: (() -> Void)?
    var onControlPermission: (() -> Void)?
    var onDiagnostics: (() -> Void)?
    var onClose: (() -> Void)?
    let status = label("Sharing is off", size: 14, weight: .medium)
    let detail = label("Start sharing, then copy the pairing code to MacLink on your other Mac.", color: .secondaryLabelColor)
    let toggle = NSButton(title: "Start Sharing", target: nil, action: nil)
    let copy = NSButton(title: "Copy Pairing Code", target: nil, action: nil)
    let control = NSButton(title: "Enable Keyboard & Mouse…", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 335),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Share This Mac"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let title = label("Your Mac, wherever you work", size: 22, weight: .semibold)
        let note = label("Pairing allows viewing and, when enabled, keyboard and mouse control. Keep the code private. Closing this window stops sharing.", size: 12, color: .secondaryLabelColor)
        let reset = NSButton(title: "Reset Pairing", target: self, action: #selector(resetPairing))
        let diagnostics = NSButton(title: "Save Diagnostics…", target: self, action: #selector(saveDiagnostics))
        toggle.target = self; toggle.action = #selector(toggleSharing); toggle.keyEquivalent = "\r"
        copy.target = self; copy.action = #selector(copyCode); copy.isEnabled = false
        control.target = self; control.action = #selector(enableControl)
        for button in [toggle, copy, control, reset, diagnostics] { button.bezelStyle = .rounded }
        let actions = stack([toggle, copy], orientation: .horizontal, spacing: 10)
        let extras = stack([reset, diagnostics], orientation: .horizontal, spacing: 10)
        let body = stack([title, status, detail, actions, control, note, extras], spacing: 15)
        let root = window.contentView!; root.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 24)
        ])
        for view in [title, detail, note] { view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func toggleSharing() { onToggle?() }
    @objc private func copyCode() { onCopy?() }
    @objc private func resetPairing() { onReset?() }
    @objc private func enableControl() { onControlPermission?() }
    @objc private func saveDiagnostics() { onDiagnostics?() }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

final class NativePairWindow: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onConnect: ((String, String) -> Void)?
    let code = NSSecureTextField(string: "")
    let address = NSTextField(string: "")
    let error = label("", size: 12, color: .systemRed)
    let connect = NSButton(title: "Pair & Connect", target: nil, action: nil)
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 335),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Connect with MacLink"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let heading = label("Pair once. Connect anytime.", size: 22, weight: .semibold)
        let note = label("On your other Mac, open MacLink → Share This Mac → Start Sharing, then copy its pairing code here.", color: .secondaryLabelColor)
        code.placeholderString = "Paste pairing code"; code.setAccessibilityLabel("Pairing code")
        address.placeholderString = "Optional — uses the address in the code"; address.setAccessibilityLabel("Mac address override")
        let form = NSGridView(views: [[label("Pairing code"), code], [label("Address"), address]])
        form.rowSpacing = 14; form.columnSpacing = 14
        form.column(at: 1).xPlacement = .fill
        connect.target = self; connect.action = #selector(pair); connect.bezelStyle = .rounded; connect.keyEquivalent = "\r"
        let body = stack([heading, note, form, error, connect], spacing: 18)
        let root = window.contentView!; root.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            body.topAnchor.constraint(equalTo: root.topAnchor, constant: 24)
        ])
        for view in [note, form, error] { view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        window.initialFirstResponder = code
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func pair() { onConnect?(code.stringValue, address.stringValue) }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func setBusy(_ busy: Bool) {
        connect.isEnabled = !busy; code.isEnabled = !busy; address.isEnabled = !busy
        connect.title = busy ? "Connecting…" : "Pair & Connect"
    }
}

final class NativeRemoteView: NativeVideoView {
    var onInput: ((NSEvent) -> Void)?
    var onReleaseInput: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var commandKeyUps: NativeCommandKeyUpMonitor?
    override var acceptsFirstResponder: Bool { true }
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
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Keep the macOS full-screen escape chord local; other Command chords
        // belong to the remote desktop while this view has keyboard focus.
        if event.modifierFlags.contains([.command, .control]) && event.keyCode == 3 { return false }
        guard window?.firstResponder === self, event.type == .keyDown,
              event.modifierFlags.contains(.command) else { return false }
        onInput?(event); return true
    }
}

final class NativeViewerWindow: NSWindowController, NSWindowDelegate {
    let video = NativeRemoteView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    let status = label("Connecting…", size: 12, color: .secondaryLabelColor)
    var onClose: (() -> Void)?
    var onReleaseInput: (() -> Void)?
    var onDiagnostics: (() -> Void)?
    init(name: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = name + " — MacLink"
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
        let bar = stack([status, NSView(), diagnostics], orientation: .horizontal, spacing: 12)
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func windowDidResignKey(_ notification: Notification) { onReleaseInput?() }
    func windowDidMiniaturize(_ notification: Notification) { onReleaseInput?() }
    @objc private func saveDiagnostics() { onDiagnostics?() }
}
