import AppKit

/// What the Settings window shows. Every change applies at once through the
/// app's own setters, so a running session follows it.
struct MacLinkSettingsState {
    var sharesAutomatically = false
    var sharesClipboard = true
    var keyboardAndMouseAllowed = false
    /// Macs approved to connect to this one, nil if the list couldn't be
    /// read; the one viewing now ("" when it used the old code); and whether
    /// the old pairing code still works.
    var devices: [NativeDevice]? = []
    var connectedDeviceID: String?
    var legacy = NativeLegacyState()
    var matchesScreen = true
    var playsSound = true
    var lowersDisplayLatency = false
    var launchesAtLogin = false
    var loginNeedsApproval = false
    /// Macs this Mac connects to, and the one connected now.
    var peers: [NativePeer] = []
    var connectedPeerID: String?
    /// For example "0.3.0 preview 19 (build 24)".
    var version = ""
    enum Updates: Equatable { case unavailable, available, ready(String) }
    var updates = Updates.unavailable
}

enum MacLinkSetting {
    case sharesAutomatically, sharesClipboard, matchesScreen, playsSound, lowersDisplayLatency, launchesAtLogin
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One window for everything a person may want to change, in three parts:
/// sharing this Mac, viewing another, and MacLink itself. Apple Screen
/// Sharing automation keeps its own window, opened from here.
final class MacLinkSettingsWindow: NSWindowController, NSWindowDelegate {
    var onChange: ((MacLinkSetting, Bool) -> Void)?
    var onRemovePeer: ((NativePeer) -> Void)?
    var onRemoveDevice: ((NativeDevice) -> Void)?
    var onStopOldCode: (() -> Void)?
    var onExtendOldCode: (() -> Void)?
    var onShareThisMac: (() -> Void)?
    var onAllowKeyboardAndMouse: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onInstallUpdate: (() -> Void)?
    var onAutomationSettings: (() -> Void)?
    /// The window came forward, perhaps after a change in System Settings.
    var onAppear: (() -> Void)?

    private var state = MacLinkSettingsState()
    private let sharesAutomatically = NSButton(checkboxWithTitle: "Share this Mac automatically", target: nil, action: nil)
    private let sharesClipboard = NSButton(checkboxWithTitle: "Share the clipboard with the connected Mac", target: nil, action: nil)
    private let keyboardAndMouse = label("", size: 12, color: .secondaryLabelColor)
    private let allowKeyboardAndMouse = NSButton(title: "Allow Keyboard & Mouse…", target: nil, action: nil)
    private let matchesScreen = NSButton(checkboxWithTitle: "Match the shared screen to this Mac", target: nil, action: nil)
    private let playsSound = NSButton(checkboxWithTitle: "Play sound from the shared Mac", target: nil, action: nil)
    private let lowersDisplayLatency = NSButton(checkboxWithTitle: "Lower display latency (may tear)", target: nil, action: nil)
    private let peerList = stack([], spacing: 8)
    private let deviceList = stack([], spacing: 8)
    private let legacyNote = label("", size: 12, color: .secondaryLabelColor)
    private let stopOldCode = NSButton(title: "Stop Now…", target: nil, action: nil)
    private let extendOldCode = NSButton(title: "Another Week", target: nil, action: nil)
    private lazy var legacyRow = stack([legacyNote, stack([stopOldCode, extendOldCode], orientation: .horizontal, spacing: 8)], spacing: 6)
    private let launchesAtLogin = NSButton(checkboxWithTitle: "Launch MacLink at login", target: nil, action: nil)
    private let loginNote = label("Approve MacLink in System Settings → General → Login Items.", size: 12, color: .secondaryLabelColor)
    private let version = label("", size: 13)
    private let updateNote = label("", size: 12, color: .secondaryLabelColor)
    private let updateButton = NSButton(title: "Check for Updates…", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "MacLink Settings"
        window.minSize = NSSize(width: 520, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MacLinkSettings")
        super.init(window: window)
        window.delegate = self
        configure()
        layout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        let toggles: [(NSButton, MacLinkSetting)] = [
            (sharesAutomatically, .sharesAutomatically), (sharesClipboard, .sharesClipboard), (matchesScreen, .matchesScreen),
            (playsSound, .playsSound), (lowersDisplayLatency, .lowersDisplayLatency), (launchesAtLogin, .launchesAtLogin)
        ]
        for (button, setting) in toggles {
            button.target = self; button.action = #selector(toggled(_:))
            button.identifier = NSUserInterfaceItemIdentifier("\(setting)")
            button.setAccessibilityLabel(button.title)
        }
        for button in [allowKeyboardAndMouse, updateButton, stopOldCode, extendOldCode] { button.bezelStyle = .rounded; button.target = self }
        for button in [stopOldCode, extendOldCode] { button.controlSize = .small }
        stopOldCode.action = #selector(stopOld)
        extendOldCode.action = #selector(extendOld)
        extendOldCode.toolTip = "Keep accepting the old code for seven days from now."
        allowKeyboardAndMouse.action = #selector(allowKeys)
        updateButton.action = #selector(updates)
    }

    private func section(_ title: String, _ note: String?, _ views: [NSView]) -> NSStackView {
        var content: [NSView] = [label(title, size: 13, weight: .semibold)]
        if let note { content.append(label(note, size: 12, color: .secondaryLabelColor)) }
        return stack(content + views, spacing: 9)
    }
    private func hint(_ text: String) -> NSTextField { label(text, size: 12, color: .secondaryLabelColor) }
    /// A checkbox with its explanation lined up under its title.
    private func option(_ button: NSButton, _ text: String) -> NSStackView {
        let note = hint(text)
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let indented = stack([note], spacing: 0)
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        let option = stack([button, indented], spacing: 3)
        indented.widthAnchor.constraint(equalTo: option.widthAnchor).isActive = true
        return option
    }
    private func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }

    private func layout() {
        guard let root = window?.contentView else { return }
        let share = NSButton(title: "Share This Mac…", target: self, action: #selector(shareThisMac))
        let automation = NSButton(title: "Apple Screen Sharing Automation…", target: self, action: #selector(automationSettings))
        for button in [share, automation] { button.bezelStyle = .rounded }
        let sharing = section("Sharing this Mac", nil, [
            option(sharesAutomatically, "Starts when MacLink opens and resumes after sleep or lock."),
            option(sharesClipboard, "Items that password managers mark as private are never shared."),
            stack([keyboardAndMouse, allowKeyboardAndMouse], spacing: 6),
            label("Macs that can connect to this Mac", size: 12, weight: .medium),
            deviceList,
            legacyRow,
            share
        ])
        let viewing = section("Viewing another Mac", nil, [
            option(matchesScreen, "The sharing Mac shows a screen exactly this Mac's size, pixel for pixel."),
            option(playsSound, "Sound also keeps playing on the sharing Mac."),
            option(lowersDisplayLatency, "Shows each frame without waiting for this display's next refresh. Sooner, but moving pictures can show a tear line."),
            label("Paired Macs", size: 12, weight: .medium),
            peerList
        ])
        let general = section("MacLink", nil, [
            stack([launchesAtLogin, loginNote], spacing: 3),
            version,
            stack([updateNote, updateButton], spacing: 6),
            automation
        ])
        let body = stack([sharing, separator(), viewing, separator(), general], spacing: 20)
        body.detachesHiddenViews = true
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.documentView = document
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 26),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -26),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22)
        ])
        for view in body.arrangedSubviews { view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        // Text and grouped options span the column and wrap; buttons keep their size.
        for part in [sharing, viewing, general] {
            for view in part.arrangedSubviews {
                if view is NSStackView || view is NSTextField {
                    view.widthAnchor.constraint(equalTo: part.widthAnchor).isActive = true
                } else {
                    view.widthAnchor.constraint(lessThanOrEqualTo: part.widthAnchor).isActive = true
                }
            }
        }
    }

    /// Shows `state`; call again whenever it may have changed.
    func show(_ state: MacLinkSettingsState) {
        self.state = state
        sharesAutomatically.state = state.sharesAutomatically ? .on : .off
        sharesClipboard.state = state.sharesClipboard ? .on : .off
        keyboardAndMouse.stringValue = state.keyboardAndMouseAllowed
            ? "Keyboard and mouse control is allowed. A viewer can control this Mac."
            : "Viewers can only watch until you allow MacLink in Accessibility."
        allowKeyboardAndMouse.isHidden = state.keyboardAndMouseAllowed
        matchesScreen.state = state.matchesScreen ? .on : .off
        playsSound.state = state.playsSound ? .on : .off
        lowersDisplayLatency.state = state.lowersDisplayLatency ? .on : .off
        launchesAtLogin.state = state.launchesAtLogin ? .on : .off
        loginNote.isHidden = !state.loginNeedsApproval
        version.stringValue = "Version \(state.version)"
        switch state.updates {
        case .unavailable:
            updateNote.stringValue = "This build doesn't update itself."
            updateButton.isHidden = true
        case .available:
            updateNote.stringValue = "Updates install by themselves while MacLink is idle."
            updateButton.isHidden = false; updateButton.title = "Check for Updates…"
        case .ready(let name):
            updateNote.stringValue = "\(name) is ready. It installs by itself while MacLink is idle."
            updateButton.isHidden = false; updateButton.title = "Install Now & Relaunch"
        }
        rebuildPeers()
        rebuildDevices()
    }

    private static let dates: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short; return formatter
    }()
    private static let days: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .none; return formatter
    }()
    private static func ago(_ date: Date) -> String {
        date > Date().addingTimeInterval(-60) ? "just now" : RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func rebuildDevices() {
        deviceList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let devices = state.devices else {
            deviceList.addArrangedSubview(hint("The list of approved Macs couldn't be read. No Mac can connect until it can."))
            legacyRow.isHidden = true
            return
        }
        if devices.isEmpty {
            deviceList.addArrangedSubview(hint("None yet. Copy a pairing code in Share This Mac, then paste it into Connect with MacLink on the other Mac."))
        }
        for device in devices {
            let connected = device.id == state.connectedDeviceID
            let name = label(String(device.name.prefix(60)) + (connected ? " · connected now" : ""), size: 13)
            var detail = "Paired \(Self.days.string(from: device.paired))"
            if device.migrated { detail += " from the old code" }
            if !connected { detail += " · last connected \(Self.ago(device.lastSeen))" }
            let remove = NSButton(title: "Remove…", target: self, action: #selector(removeDevice(_:)))
            remove.bezelStyle = .rounded; remove.controlSize = .small
            remove.identifier = NSUserInterfaceItemIdentifier(device.id)
            remove.toolTip = "Stop this Mac from connecting until it pairs again."
            let row = stack([stack([name, label(detail, size: 11, color: .secondaryLabelColor)], spacing: 2), NSView(), remove],
                            orientation: .horizontal, spacing: 10)
            deviceList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: deviceList.widthAnchor).isActive = true
        }
        let legacy = state.legacy
        legacyRow.isHidden = !legacy.accepted
        guard legacy.accepted else { return }
        var note: String
        switch legacy.closesAt {
        case nil:
            note = "Macs paired with an earlier MacLink still connect with the old pairing code. Each gets its own key the next time "
                + "it connects, and the old code stops a week after the first one does."
        case let closes? where legacy.isOpen:
            note = "Macs paired with an earlier MacLink can use the old pairing code until \(Self.dates.string(from: closes)). "
                + "Each gets its own key the next time it connects. Check that every Mac above is yours."
        case let closes?:
            note = "The old pairing code stopped working \(Self.dates.string(from: closes)). "
                + "A Mac that didn't get its own key by then needs a new code."
        }
        if let used = legacy.lastUsed { note += " Last used \(Self.ago(used))." }
        legacyNote.stringValue = note
        stopOldCode.isHidden = !legacy.isOpen
        // Without an end date there's nothing to extend, and once past it, it stays stopped.
        extendOldCode.isHidden = legacy.closesAt == nil || !legacy.isOpen
    }

    private func rebuildPeers() {
        peerList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !state.peers.isEmpty else {
            peerList.addArrangedSubview(hint("None yet. Use Connect with MacLink and a pairing code from the other Mac."))
            return
        }
        for peer in state.peers {
            let name = label(String(peer.name.prefix(60)), size: 13)
            let more = peer.alternates.isEmpty ? "" : " · \(peer.alternates.count) more"
            let address = label(peer.address + more, size: 11, color: .secondaryLabelColor)
            address.toolTip = peer.addresses.joined(separator: "\n")
            let remove = NSButton(title: "Remove…", target: self, action: #selector(removePeer(_:)))
            remove.bezelStyle = .rounded; remove.controlSize = .small
            remove.identifier = NSUserInterfaceItemIdentifier(peer.id)
            let connected = peer.id == state.connectedPeerID
            remove.isEnabled = !connected
            remove.toolTip = connected ? "Disconnect from this Mac first." : "Forget this pairing on this Mac."
            let row = stack([stack([name, address], spacing: 2), NSView(), remove], orientation: .horizontal, spacing: 10)
            peerList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: peerList.widthAnchor).isActive = true
        }
    }

    @objc private func toggled(_ sender: NSButton) {
        let settings: [String: MacLinkSetting] = [
            "sharesAutomatically": .sharesAutomatically, "sharesClipboard": .sharesClipboard, "matchesScreen": .matchesScreen,
            "playsSound": .playsSound, "lowersDisplayLatency": .lowersDisplayLatency, "launchesAtLogin": .launchesAtLogin
        ]
        guard let key = sender.identifier?.rawValue, let setting = settings[key] else { return }
        onChange?(setting, sender.state == .on)
    }
    @objc private func removePeer(_ sender: NSButton) {
        guard let window, let peer = state.peers.first(where: { $0.id == sender.identifier?.rawValue }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(peer.name)?"
        alert.informativeText = "This Mac forgets the pairing. To connect again, you'll need a new pairing code from that Mac."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.onRemovePeer?(peer) }
        }
    }
    @objc private func removeDevice(_ sender: NSButton) {
        guard let window, let device = state.devices?.first(where: { $0.id == sender.identifier?.rawValue }) else { return }
        let connected = device.id == state.connectedDeviceID
        let alert = NSAlert()
        alert.messageText = "Remove \(device.name)?"
        alert.informativeText = (connected ? "It disconnects now. " : "")
            + "It can't connect to this Mac again until you pair it with a new code."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.onRemoveDevice?(device) }
        }
    }
    @objc private func stopOld() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Stop accepting the old pairing code?"
        alert.informativeText = "Macs that haven't connected since you updated will need a new pairing code. "
            + (state.connectedDeviceID == "" ? "The Mac using it now disconnects. " : "") + "This can't be undone."
        alert.addButton(withTitle: "Stop Now"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.onStopOldCode?() }
        }
    }
    @objc private func extendOld() { onExtendOldCode?() }
    func windowDidBecomeKey(_ notification: Notification) { onAppear?() }
    @objc private func allowKeys() { onAllowKeyboardAndMouse?() }
    @objc private func shareThisMac() { onShareThisMac?() }
    @objc private func automationSettings() { onAutomationSettings?() }
    @objc private func updates() {
        if case .ready = state.updates { onInstallUpdate?() } else { onCheckForUpdates?() }
    }
}
