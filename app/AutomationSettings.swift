import AppKit
import ServiceManagement

struct AutomationSettings: Codable {
    var enabled: Bool = false
    var paused: Bool = false
    var targetID: String = ""
    var homeRoute: String = ""
    var additionalHomeRoutes: [String] = []
    var allowVPN: Bool = false
    var highPerformanceConfirmed: Bool = false
    var fullScreen: Bool = true
    var autoConnect: Bool = true
    var preference: String = "auto"

    var homeRoutes: [String] {
        var seen = Set<String>()
        return Array(([homeRoute] + additionalHomeRoutes)
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(8))
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, paused, targetID, homeRoute, additionalHomeRoutes, allowVPN
        case highPerformanceConfirmed, fullScreen, autoConnect, preference
    }
}

extension AutomationSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? paused
        targetID = try values.decodeIfPresent(String.self, forKey: .targetID) ?? targetID
        homeRoute = try values.decodeIfPresent(String.self, forKey: .homeRoute) ?? homeRoute
        additionalHomeRoutes = try values.decodeIfPresent([String].self, forKey: .additionalHomeRoutes) ?? []
        allowVPN = try values.decodeIfPresent(Bool.self, forKey: .allowVPN) ?? allowVPN
        highPerformanceConfirmed = try values.decodeIfPresent(Bool.self, forKey: .highPerformanceConfirmed) ?? highPerformanceConfirmed
        fullScreen = try values.decodeIfPresent(Bool.self, forKey: .fullScreen) ?? fullScreen
        autoConnect = try values.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? autoConnect
        preference = try values.decodeIfPresent(String.self, forKey: .preference) ?? preference
        additionalHomeRoutes = Array(homeRoutes.filter { $0 != homeRoute }.prefix(homeRoute.isEmpty ? 8 : 7))
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class AutomationSettingsController: NSWindowController, NSWindowDelegate {
    var onSave: ((AutomationSettings, Bool) -> Void)?
    var onCheckHome: (() -> Void)?
    var selectedTargetID: String { targetPopup.selectedItem?.representedObject as? String ?? "" }

    private var draft: AutomationSettings
    private var currentFingerprint: String?
    private var checkingHome = false
    private var routeRequestGeneration = 0
    private var homePathsEdited = false
    private let enabledButton = NSButton(checkboxWithTitle: "Enable automation", target: nil, action: nil)
    private let targetPopup = NSPopUpButton()
    private let loginButton = NSButton(checkboxWithTitle: "Launch MacLink at login", target: nil, action: nil)
    private let autoConnectButton = NSButton(checkboxWithTitle: "Connect automatically on a healthy home path", target: nil, action: nil)
    private let fullScreenButton = NSButton(checkboxWithTitle: "Open the remote session in full screen", target: nil, action: nil)
    private let preferencePopup = NSPopUpButton()
    private let preferenceDetail = label("", size: 12, color: .secondaryLabelColor)
    private let supportedButton = NSButton(checkboxWithTitle: "Both Macs support High Performance screen sharing", target: nil, action: nil)
    private let vpnButton = NSButton(checkboxWithTitle: "Allow VPN paths for High Performance", target: nil, action: nil)
    private let routeDescription = label("Check the current path before marking it as home.", size: 12, color: .secondaryLabelColor)
    private let homeDescription = label("No home path saved.", size: 12, color: .secondaryLabelColor)
    private let checkHomeButton = NSButton(title: "Check Current Path", target: nil, action: nil)
    private let markHomeButton = NSButton(title: "Mark This Path as Home", target: nil, action: nil)
    private let forgetHomeButton = NSButton(title: "Forget Home Paths", target: nil, action: nil)
    private let permissionDescription = label("", size: 12, color: .secondaryLabelColor)
    private let permissionButton = NSButton(title: "Allow Accessibility…", target: nil, action: nil)
    private let validationLabel = label("", size: 11, color: .systemRed)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(settings: AutomationSettings, connections: [SavedMac]) {
        draft = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 660),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "MacLink Settings"
        window.minSize = NSSize(width: 580, height: 540)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MacLinkAutomationSettings")
        configureControls(connections: connections)
        buildLayout()
        updatePreference()
        updatePermission()
        validate()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configureControls(connections: [SavedMac]) {
        enabledButton.state = draft.enabled ? .on : .off
        autoConnectButton.state = draft.autoConnect ? .on : .off
        fullScreenButton.state = draft.fullScreen ? .on : .off
        supportedButton.state = draft.highPerformanceConfirmed ? .on : .off
        vpnButton.state = draft.allowVPN ? .on : .off
        loginButton.state = SMAppService.mainApp.status == .enabled ? .on : .off

        for button in [enabledButton, autoConnectButton, fullScreenButton, supportedButton, vpnButton, loginButton] {
            button.target = self
            button.action = #selector(controlChanged)
            button.setAccessibilityLabel(button.title)
        }
        if connections.isEmpty {
            targetPopup.addItem(withTitle: "Add a Mac in Open Connections first")
            targetPopup.isEnabled = false
        } else {
            for mac in connections {
                let name = mac.name.count > 40 ? String(mac.name.prefix(39)) + "…" : mac.name
                targetPopup.addItem(withTitle: name)
                targetPopup.lastItem?.representedObject = mac.id
                targetPopup.lastItem?.toolTip = "\(mac.name) — \(mac.endpoint)"
            }
            if let index = connections.firstIndex(where: { $0.id == draft.targetID }) {
                targetPopup.selectItem(at: index)
            } else if !draft.targetID.isEmpty {
                targetPopup.insertItem(withTitle: "Choose a saved Mac…", at: 0)
                targetPopup.selectItem(at: 0)
            }
        }
        targetPopup.target = self
        targetPopup.action = #selector(targetChanged)
        targetPopup.setAccessibilityLabel("Mac to automate")
        for (title, value) in [("Auto", "auto"), ("Standard", "standard"), ("Prefer High Performance", "high_performance")] {
            preferencePopup.addItem(withTitle: title)
            preferencePopup.lastItem?.representedObject = value
        }
        if let item = preferencePopup.itemArray.first(where: { $0.representedObject as? String == draft.preference }) {
            preferencePopup.select(item)
        }
        preferencePopup.target = self
        preferencePopup.action = #selector(controlChanged)
        preferencePopup.setAccessibilityLabel("Preferred screen sharing mode")
        routeDescription.maximumNumberOfLines = 3
        routeDescription.lineBreakMode = .byTruncatingMiddle
        updateHomeDescription()
        for button in [checkHomeButton, markHomeButton, forgetHomeButton, permissionButton, saveButton] { button.bezelStyle = .rounded }
        checkHomeButton.target = self
        checkHomeButton.action = #selector(checkHome)
        markHomeButton.target = self
        markHomeButton.action = #selector(markHome)
        markHomeButton.isEnabled = false
        forgetHomeButton.target = self
        forgetHomeButton.action = #selector(forgetHome)
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
    }

    private func section(_ title: String, _ views: [NSView]) -> NSStackView {
        let content = stack([label(title, size: 13, weight: .semibold)] + views, spacing: 9)
        for view in views where view is NSTextField || view is NSGridView {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if let text = view as? NSTextField { text.preferredMaxLayoutWidth = 510 }
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        return content
    }

    private func separator() -> NSBox {
        let view = NSBox()
        view.boxType = .separator
        return view
    }

    private func buildLayout() {
        guard let window, let root = window.contentView else { return }
        let title = label("Automation", size: 23, weight: .semibold)
        let subtitle = label("Choose when MacLink connects and how it opens your Mac.", size: 13, color: .secondaryLabelColor)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.preferredMaxLayoutWidth = 540
        let heading = stack([title, subtitle], spacing: 6)
        root.addSubview(heading)

        let target = NSGridView(views: [[label("Mac"), targetPopup]])
        target.columnSpacing = 16
        target.column(at: 0).width = 68
        target.column(at: 1).xPlacement = .fill
        target.row(at: 0).yPlacement = .center
        var generalViews: [NSView] = [enabledButton, target, loginButton, autoConnectButton, fullScreenButton]
        if draft.paused {
            generalViews.append(label("Automation is paused. Resume it from the MacLink menu when you’re ready.", size: 12, color: .secondaryLabelColor))
        }
        if SMAppService.mainApp.status == .requiresApproval {
            generalViews.append(label("Login launch needs approval in System Settings → General → Login Items.", size: 12, color: .secondaryLabelColor))
        }
        let general = section("Connection", generalViews)

        let mode = NSGridView(views: [[label("Mode"), preferencePopup]])
        mode.columnSpacing = 16
        mode.column(at: 0).width = 68
        mode.column(at: 1).xPlacement = .fill
        mode.row(at: 0).yPlacement = .center
        let display = section("Display", [mode, preferenceDetail, supportedButton, vpnButton])

        let homeActions = stack([checkHomeButton, markHomeButton, forgetHomeButton], orientation: .horizontal, spacing: 8)
        let networkNote = label("Mark your home Wi-Fi and Ethernet paths separately; up to eight paths are kept. A Ubiquiti bridge or travel router can make home and travel look identical. Saved paths are hints; connection measurements do not guarantee available bandwidth.", size: 12, color: .secondaryLabelColor)
        let network = section("Home network", [routeDescription, homeActions, homeDescription, networkNote])

        let permissionNote = label("Accessibility lets MacLink identify its Screen Sharing window, enter full screen and reconnect that session when changing modes. Passwords stay in Apple Screen Sharing.", size: 12, color: .secondaryLabelColor)
        let permissions = section("Accessibility", [permissionNote, permissionDescription, permissionButton])
        let limitations = label("Changing modes reconnects the session. High Performance may blank the remote Mac’s physical display. Mode requests use an experimental Apple Screen Sharing URL and may not work on every macOS version.", size: 12, color: .secondaryLabelColor)
        limitations.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        limitations.preferredMaxLayoutWidth = 510

        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let body = stack([general, separator(), display, separator(), network, separator(), permissions, separator(), limitations], spacing: 20)
        document.addSubview(body)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = document
        root.addSubview(scroll)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let actions = stack([validationLabel, NSView(), cancel, saveButton], orientation: .horizontal, spacing: 10)
        validationLabel.maximumNumberOfLines = 2
        root.addSubview(actions)
        let bottomDivider = separator()
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bottomDivider)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            heading.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            subtitle.widthAnchor.constraint(equalTo: heading.widthAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
            scroll.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor, constant: -10),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 26),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -26),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            bottomDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            bottomDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            bottomDivider.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -15),
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 26),
            actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -26),
            actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            validationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 310)
        ])
        for view in body.arrangedSubviews { view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
    }

    func showRoute(_ description: String, fingerprint: String?) {
        routeRequestGeneration += 1
        checkingHome = false
        currentFingerprint = fingerprint.flatMap { $0.isEmpty ? nil : $0 }
        routeDescription.stringValue = description
        routeDescription.toolTip = description
        checkHomeButton.isEnabled = !selectedTargetID.isEmpty
        checkHomeButton.title = "Check Current Path"
        markHomeButton.isEnabled = currentFingerprint != nil
        updateHomeDescription()
    }

    private var selectedPreference: String { preferencePopup.selectedItem?.representedObject as? String ?? "auto" }

    @objc private func controlChanged() {
        updatePreference()
        validate()
    }

    @objc private func targetChanged() {
        routeRequestGeneration += 1
        checkingHome = false
        currentFingerprint = nil
        routeDescription.stringValue = "Check the current path for the selected Mac."
        routeDescription.toolTip = nil
        updateHomeDescription()
        markHomeButton.isEnabled = false
        checkHomeButton.title = "Check Current Path"
        validate()
    }

    private func updatePreference() {
        switch selectedPreference {
        case "standard": preferenceDetail.stringValue = "Requests Standard mode for this Mac."
        case "high_performance": preferenceDetail.stringValue = "Prefers High Performance when supported. Automation can fall back to Standard. Confirm below that both Macs support it."
        default: preferenceDetail.stringValue = "Uses saved home paths and connection checks to choose a mode. Confirm support below before Auto can request High Performance."
        }
        vpnButton.isEnabled = selectedPreference == "auto"
    }

    private func validate() {
        let hasTarget = !selectedTargetID.isEmpty
        checkHomeButton.isEnabled = hasTarget && !checkingHome
        if enabledButton.state == .on && !hasTarget {
            validationLabel.stringValue = "Choose a saved Mac to enable automation."
            saveButton.isEnabled = false
        } else if enabledButton.state == .on && selectedPreference == "high_performance" && supportedButton.state != .on {
            validationLabel.stringValue = "Confirm both Macs support High Performance."
            saveButton.isEnabled = false
        } else {
            validationLabel.stringValue = ""
            saveButton.isEnabled = true
        }
    }

    @objc private func checkHome() {
        guard !selectedTargetID.isEmpty, let onCheckHome else { return }
        checkingHome = true
        routeRequestGeneration += 1
        let request = routeRequestGeneration
        checkHomeButton.isEnabled = false
        checkHomeButton.title = "Checking…"
        markHomeButton.isEnabled = false
        onCheckHome()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.checkingHome, self.routeRequestGeneration == request else { return }
            self.showRoute("The path check did not finish. Try again when the selected Mac is reachable.", fingerprint: nil)
        }
    }

    @objc private func markHome() {
        guard let currentFingerprint else { return }
        let previous = draft.homeRoutes.filter { $0 != currentFingerprint }
        draft.homeRoute = currentFingerprint
        draft.additionalHomeRoutes = Array(previous.prefix(7))
        homePathsEdited = true
        updateHomeDescription()
    }

    @objc private func forgetHome() {
        draft.homeRoute = ""
        draft.additionalHomeRoutes = []
        homePathsEdited = true
        updateHomeDescription()
    }

    private func updateHomeDescription() {
        let routes = draft.homeRoutes
        forgetHomeButton.isEnabled = !routes.isEmpty
        guard !routes.isEmpty else {
            homeDescription.stringValue = homePathsEdited ? "Home paths cleared. Save to apply this change." : "No home paths saved."
            return
        }
        let noun = routes.count == 1 ? "home path" : "home paths"
        var text = "\(routes.count) \(noun) \(homePathsEdited ? "marked" : "saved")."
        if let currentFingerprint {
            text += routes.contains(currentFingerprint) ? " This path matches." : " This path is not marked as home."
        }
        if homePathsEdited { text += " Save to apply changes." }
        homeDescription.stringValue = text
    }

    @objc private func requestPermission() {
        AppleSession.requestPermission()
        updatePermission()
    }

    private func updatePermission() {
        let trusted = AppleSession.isTrusted
        permissionDescription.stringValue = trusted ? "Accessibility access is enabled." : "Access is required for full screen and session reconnection."
        permissionButton.isEnabled = !trusted
        permissionButton.title = trusted ? "Accessibility Enabled" : "Allow Accessibility…"
    }

    func windowDidBecomeKey(_ notification: Notification) { updatePermission() }

    @objc private func save() {
        validate()
        guard saveButton.isEnabled else { return }
        draft.enabled = enabledButton.state == .on
        draft.targetID = selectedTargetID
        draft.allowVPN = vpnButton.state == .on
        draft.highPerformanceConfirmed = supportedButton.state == .on
        draft.fullScreen = fullScreenButton.state == .on
        draft.autoConnect = autoConnectButton.state == .on
        draft.preference = selectedPreference
        onSave?(draft, loginButton.state == .on)
    }

    @objc private func cancel() {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        close()
    }
}
