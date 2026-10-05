import AppKit

/// A single, contextual system-permission step. It never grants access itself.
final class ConnectionPermissionController: NSWindowController, NSWindowDelegate {
    var onComplete: ((Bool?) -> Void)?
    private var timer: Timer?
    private var finished = false
    private var deadline: TimeInterval = 0
    private let detail = label("Allow Mooring in macOS Accessibility to open your remote Mac in full screen and adjust its connection automatically.", color: .secondaryLabelColor)
    private let allow = NSButton(title: "Enable & Connect…", target: nil, action: nil)

    init(macName: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Connect to \(macName)"
        MooringAppearance.prepare(window)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let heading = MooringAppearance.header("Allow session control", subtitle: "For full screen and automatic connections.")
        let manual = NSButton(title: "Connect Without Automation", target: self, action: #selector(connectManually))
        manual.bezelStyle = .rounded
        allow.target = self; allow.action = #selector(requestAccess); allow.bezelStyle = .rounded
        MooringAppearance.primary(allow)
        allow.keyEquivalent = "\r"
        let note = label("You can change your preferences later in Settings.", size: 12, color: .secondaryLabelColor)
        let content = stack([heading, detail, note, allow, manual], spacing: 18)
        let root = window.contentView!
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            heading.widthAnchor.constraint(equalTo: content.widthAnchor),
            detail.widthAnchor.constraint(equalTo: content.widthAnchor),
            note.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func requestAccess() {
        AppleSession.requestPermission()
        detail.stringValue = "Turn on Mooring in macOS Accessibility. Your connection will open as soon as access is enabled."
        allow.title = "Open Accessibility Settings…"
        // Open the relevant system pane; macOS still requires the user to grant access.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        deadline = ProcessInfo.processInfo.systemUptime + 300
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                if AppleSession.isTrusted { self.finish(true) }
                else if ProcessInfo.processInfo.systemUptime >= self.deadline {
                    self.timer?.invalidate(); self.timer = nil
                    self.detail.stringValue = "Access is still off. Enable it to continue, or connect without automation."
                }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        }
    }
    @objc private func connectManually() { finish(false) }
    private func finish(_ enabled: Bool?) {
        guard !finished else { return }
        finished = true; timer?.invalidate(); timer = nil
        close()
        let completion = onComplete; onComplete = nil; completion?(enabled)
    }
    func windowWillClose(_ notification: Notification) { finish(nil) }
    func cancel() { finish(nil) }
    deinit { timer?.invalidate() }
}
