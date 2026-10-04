import AppKit
import ServiceManagement

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class AutomationSettingsController: NSWindowController, NSWindowDelegate {
    var onSave: ((AutomationSettings, Bool) -> Void)?
    var onCheckHome: ((UUID) -> Void)?
    var selectedTargetID: String { targetPopup.selectedItem?.representedObject as? String ?? "" }

    private var draft: AutomationSettings
    private var homeCheck = HomeNetworkCheck()
    private var homePathsEdited = false
    private let advancedButton = NSButton(title: "Advanced…", target: nil, action: nil)
    private var advancedContent: NSStackView?
    private let trialButton = NSButton(checkboxWithTitle: "Try High Performance automatically on familiar direct networks", target: nil, action: nil)
    private let enabledButton = NSButton(checkboxWithTitle: "Enable automation", target: nil, action: nil)
    private let targetPopup = NSPopUpButton()
    private let loginButton = NSButton(checkboxWithTitle: "Launch MacLink at login", target: nil, action: nil)
    private let autoConnectButton = NSButton(checkboxWithTitle: "Reconnect automatically on familiar networks", target: nil, action: nil)
    private let fullScreenButton = NSButton(checkboxWithTitle: "Open the remote session in full screen", target: nil, action: nil)
    private let preferencePopup = NSPopUpButton()
    private let preferenceDetail = label("", size: 12, color: .secondaryLabelColor)
    private let supportedButton = NSButton(checkboxWithTitle: "Both Macs support High Performance screen sharing", target: nil, action: nil)
    private let vpnButton = NSButton(checkboxWithTitle: "Allow VPN paths for High Performance", target: nil, action: nil)
    private let routeDescription = label("Detect the Wi-Fi or Ethernet network this Mac is using.", size: 12, color: .secondaryLabelColor)
    private let homeDescription = label("No home path saved.", size: 12, color: .secondaryLabelColor)
    private let checkHomeButton = NSButton(title: "Detect Network", target: nil, action: nil)
    private let markHomeButton = NSButton(title: "Use This Network as Home", target: nil, action: nil)
    private let forgetHomeButton = NSButton(title: "Forget Home Paths", target: nil, action: nil)
    private let permissionDescription = label("", size: 12, color: .secondaryLabelColor)
    private let permissionButton = NSButton(title: "Allow Accessibility…", target: nil, action: nil)
    private let validationLabel = label("", size: 11, color: .systemRed)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    init(settings: AutomationSettings, connections: [SavedMac]) {
        draft = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 540),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Screen Sharing Settings"
        MacLinkAppearance.prepare(window)
        window.minSize = NSSize(width: 580, height: 540)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MacLinkSimpleSettings")
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
        trialButton.state = draft.automaticHighPerformanceTrial ? .on : .off
        vpnButton.state = draft.allowVPN ? .on : .off
        loginButton.state = SMAppService.mainApp.status == .enabled ? .on : .off

        for button in [enabledButton, autoConnectButton, fullScreenButton, supportedButton, trialButton, vpnButton, loginButton] {
            button.target = self
            button.action = #selector(controlChanged)
            button.setAccessibilityLabel(button.title)
        }
        updateConnections(connections)
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
        MacLinkAppearance.primary(saveButton)
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
        let heading = MacLinkAppearance.header("Screen Sharing", subtitle: "Display and automation preferences for Apple Screen Sharing.")
        root.addSubview(heading)

        let target = NSGridView(views: [[label("Mac"), targetPopup]])
        target.columnSpacing = 16
        target.column(at: 0).width = 68
        target.column(at: 1).xPlacement = .fill
        target.row(at: 0).yPlacement = .center
        var generalViews: [NSView] = [autoConnectButton, fullScreenButton, loginButton]
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
        let display = section("Display", [mode, preferenceDetail])

        let homeActions = stack([checkHomeButton, markHomeButton], orientation: .horizontal, spacing: 8)
        let networkIntro = label("Optional override. MacLink remembers familiar direct networks after you connect. You can also mark home networks yourself.", size: 12, color: .secondaryLabelColor)
        let networkNote = label("Add your home Wi-Fi and Ethernet networks separately; up to eight are kept. A travel router or bridge can make locations look alike. Home detection does not guarantee available bandwidth.", size: 12, color: .secondaryLabelColor)
        let network = section("Home network", [networkIntro, routeDescription, homeActions, homeDescription, forgetHomeButton, networkNote])

        let permissionNote = label("Accessibility lets MacLink identify its Screen Sharing window, enter full screen and reconnect that session when changing modes. Passwords stay in Apple Screen Sharing.", size: 12, color: .secondaryLabelColor)
        let permissions = section("Accessibility", [permissionNote, permissionDescription, permissionButton])
        let limitations = label("Changing modes reconnects the session. High Performance may blank the remote Mac’s physical display. Mode requests use an experimental Apple Screen Sharing URL and may not work on every macOS version.", size: 12, color: .secondaryLabelColor)
        limitations.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        limitations.preferredMaxLayoutWidth = 510

        let document = SettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let advanced = stack([section("Automation", [enabledButton, target, trialButton, supportedButton, vpnButton]), separator(), network, separator(), permissions, separator(), limitations], spacing: 20)
        advanced.isHidden = true
        advancedContent = advanced
        advancedButton.bezelStyle = .inline
        advancedButton.setButtonType(.onOff)
        advancedButton.target = self; advancedButton.action = #selector(toggleAdvanced)
        advancedButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        advancedButton.imagePosition = .imageLeading
        let body = stack([general, separator(), display, advancedButton, advanced], spacing: 20)
        body.detachesHiddenViews = true
        for view in advanced.arrangedSubviews { view.widthAnchor.constraint(equalTo: advanced.widthAnchor).isActive = true }
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
        for view in body.arrangedSubviews where view !== advancedButton {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
    }

    func completeHomeCheck(request: UUID, description: String, fingerprint: String?) {
        guard homeCheck.complete(request: request, description: description, fingerprint: fingerprint) else { return }
        renderHomeCheck()
    }

    func invalidateHomeCheck(reason: String) {
        homeCheck.invalidate(reason: reason)
        renderHomeCheck()
    }

    private func renderHomeCheck() {
        routeDescription.stringValue = homeCheck.description
        routeDescription.toolTip = homeCheck.description
        checkHomeButton.isEnabled = !homeCheck.isChecking
        checkHomeButton.title = homeCheck.isChecking ? "Detecting…" : "Detect Network"
        markHomeButton.isEnabled = homeCheck.fingerprint != nil && !homeCheck.isChecking
        updateHomeDescription()
    }

    func updateConnections(_ connections: [SavedMac]) {
        let selection = targetPopup.numberOfItems == 0 ? draft.targetID : selectedTargetID
        targetPopup.removeAllItems()
        targetPopup.isEnabled = !connections.isEmpty
        if connections.isEmpty {
            targetPopup.addItem(withTitle: "Add a Mac in Open Connections first")
        } else {
            for mac in connections {
                let name = mac.name.count > 40 ? String(mac.name.prefix(39)) + "…" : mac.name
                let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.representedObject = mac.id
                item.toolTip = "\(mac.name) — \(mac.endpoint)"
                targetPopup.menu?.addItem(item)
            }
            if let item = targetPopup.itemArray.first(where: { $0.representedObject as? String == selection }) {
                targetPopup.select(item)
            } else if !selection.isEmpty {
                targetPopup.insertItem(withTitle: "Choose a saved Mac…", at: 0)
                targetPopup.selectItem(at: 0)
            } else {
                targetPopup.selectItem(at: 0)
            }
        }
        validate()
    }

    private var selectedPreference: String { preferencePopup.selectedItem?.representedObject as? String ?? "auto" }

    @objc private func controlChanged() {
        updatePreference()
        validate()
    }

    @objc private func targetChanged() {
        validate()
    }

    private func updatePreference() {
        switch selectedPreference {
        case "standard": preferenceDetail.stringValue = "Requests Standard mode for this Mac."
        case "high_performance": preferenceDetail.stringValue = "Requests High Performance. Both Macs must support it; MacLink can fall back if connection checks deteriorate."
        default: preferenceDetail.stringValue = "Starts with Standard, learns familiar networks, and can try High Performance when connection checks stay healthy."
        }
        vpnButton.isEnabled = selectedPreference == "auto"
    }

    private func validate() {
        checkHomeButton.isEnabled = !homeCheck.isChecking
        validationLabel.stringValue = ""
        saveButton.isEnabled = true
    }

    @objc private func toggleAdvanced() {
        let expanded = advancedButton.state == .on
        advancedContent?.isHidden = !expanded
        advancedButton.title = expanded ? "Hide Advanced" : "Advanced…"
        advancedButton.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    }

    @objc private func checkHome() {
        guard !homeCheck.isChecking, let onCheckHome else { return }
        let request = homeCheck.begin()
        renderHomeCheck()
        onCheckHome(request)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.homeCheck.timeout(request: request) else { return }
            self.renderHomeCheck()
        }
    }

    @objc private func markHome() {
        guard !homeCheck.isChecking, let fingerprint = homeCheck.fingerprint else { return }
        draft.rememberHome(fingerprint)
        homePathsEdited = true
        updateHomeDescription()
    }

    @objc private func forgetHome() {
        draft.forgetHomes()
        draft.familiarPaths = []
        homePathsEdited = true
        updateHomeDescription()
    }

    private func updateHomeDescription() {
        let routes = draft.homeRoutes
        forgetHomeButton.isEnabled = !routes.isEmpty || !draft.familiarPaths.isEmpty
        guard !routes.isEmpty else {
            homeDescription.stringValue = homePathsEdited ? "Remembered networks cleared. Save to apply this change." : "\(draft.familiarPaths.count) automatically remembered; no manual home overrides."
            return
        }
        let noun = routes.count == 1 ? "home path" : "home paths"
        var text = "\(routes.count) \(noun) \(homePathsEdited ? "marked" : "saved")."
        if let fingerprint = homeCheck.fingerprint {
            text += routes.contains(fingerprint) ? " This network matches." : " This network is not marked as home."
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
        draft.automaticHighPerformanceTrial = trialButton.state == .on
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
