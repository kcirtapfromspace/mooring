import AppKit
import Foundation
import Darwin
import ServiceManagement

struct SavedMac: Decodable {
    let id: String
    let name: String
    let host: String
    let port: UInt16

    var endpoint: String {
        let address = host.contains(":") ? "[\(host)]" : host
        return port == 5900 ? host : "\(address):\(port)"
    }
}

private struct HostInspection: Decodable {
    let host: String
    let port: UInt16
    let tcp_connect_ms: Double?
    let rfb_version: String?
    let note: String?
}

struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    func expire() { lock.lock(); expired = true; lock.unlock() }
    var isExpired: Bool { lock.lock(); defer { lock.unlock() }; return expired }
}

/// The UI only launches the CLI. Connection storage, validation and probing live in Rust.
final class CLIClient {
    func run(_ arguments: [String], timeout: TimeInterval = 15,
             completion: @escaping (Result<Data, CLIError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Data, CLIError>
            do {
                let data = try self.execute(arguments, timeout: timeout)
                result = .success(data)
            } catch {
                result = .failure(CLIError(message: error.localizedDescription))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func executableURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["MACLINK_BIN"], !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw CLIError(message: "MACLINK_BIN does not point to an executable: \(override)")
            }
            return URL(fileURLWithPath: override)
        }
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("maclink"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("maclink")
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CLIError(message: "The Mooring command-line tool is missing. Rebuild the app with scripts/build-app.sh.")
        }
        return url
    }

    private func execute(_ arguments: [String], timeout: TimeInterval) throws -> Data {
        let binary = try executableURL()
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("maclink-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        for url in [outputURL, errorURL] {
            guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CLIError(message: "Could not create temporary command output.")
            }
        }
        let stdout = try FileHandle(forWritingTo: outputURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let timeoutState = TimeoutState()
        let deadline = DispatchWorkItem {
            if process.isRunning {
                timeoutState.expire()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        if timeoutState.isExpired {
            throw CLIError(message: "This operation took too long and was stopped. Check the Mac’s address and network, then try again.")
        }
        if process.terminationStatus != 0 {
            let data = (try? Data(contentsOf: errorURL)) ?? Data()
            let message = String(decoding: data.prefix(16_384), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(message: message.isEmpty ? "The Mooring command-line tool exited unexpectedly (\(process.terminationStatus))." : message)
        }
        return try Data(contentsOf: outputURL)
    }
}

func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    view.font = .systemFont(ofSize: size, weight: weight)
    view.textColor = color
    view.lineBreakMode = .byWordWrapping
    view.maximumNumberOfLines = 0
    view.preferredMaxLayoutWidth = 440
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
}

func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation = .vertical,
                   spacing: CGFloat = 12) -> NSStackView {
    let view = NSStackView(views: views)
    view.orientation = orientation
    view.alignment = orientation == .vertical ? .leading : .centerY
    view.distribution = .fill
    view.spacing = spacing
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
}

/// One row of the Connections list: an Apple Screen Sharing Mac saved by the
/// CLI store, or a Mac paired for a MacLink session.
private enum ConnectionRow {
    case screenSharing(SavedMac)
    case maclink(NativePeer)

    static func screenSharingID(_ id: String) -> String { "screen-sharing:" + id }
    var id: String {
        switch self {
        case .screenSharing(let mac): return Self.screenSharingID(mac.id)
        case .maclink(let peer): return "maclink:" + peer.id
        }
    }
    var name: String {
        switch self {
        case .screenSharing(let mac): return mac.name
        case .maclink(let peer): return peer.name
        }
    }
    var detail: String {
        switch self {
        case .screenSharing(let mac): return "Screen Sharing · " + mac.endpoint
        case .maclink(let peer): return "Paired · " + peer.address
        }
    }
    var symbol: String {
        switch self {
        case .screenSharing: return "desktopcomputer"
        case .maclink: return "bolt.horizontal.circle"
        }
    }
}

private final class MacCell: NSTableCellView {
    let nameLabel = label("", size: 13, weight: .medium)
    let hostLabel = label("", size: 11, color: .secondaryLabelColor)
    let symbol = NSImageView(image: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)!)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        symbol.contentTintColor = .secondaryLabelColor
        symbol.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        hostLabel.maximumNumberOfLines = 1
        hostLabel.lineBreakMode = .byTruncatingMiddle
        let copy = stack([nameLabel, hostLabel], spacing: 3)
        let row = stack([symbol, copy], orientation: .horizontal, spacing: 10)
        addSubview(row)
        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 26),
            symbol.heightAnchor.constraint(equalToConstant: 26),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            copy.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class AddMacController: NSWindowController, NSTextFieldDelegate {
    let nameField = NSTextField(string: "")
    let hostField = NSTextField(string: "")
    let portField = NSTextField(string: "5900")
    let errorLabel = label("", size: 12, color: .systemRed)
    let saveButton = NSButton(title: "Connect", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let optionsButton = NSButton(title: "Options", target: nil, action: nil)
    private var optionsForm: NSGridView!
    var onSave: ((String, String, String) -> Void)?
    var onCancel: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Add a Mac"
        MacLinkAppearance.prepare(window)
        let heading = MacLinkAppearance.header("Add a Mac", subtitle: "Connect using Apple Screen Sharing.")
        let subtitle = label("Enable Screen Sharing there. Enter its address here.", color: .secondaryLabelColor)
        for field in [nameField, hostField, portField] {
            field.delegate = self
            field.controlSize = .large
        }
        nameField.placeholderString = "Optional"
        hostField.placeholderString = "Mac-Studio.local or 192.168.1.20"
        nameField.setAccessibilityLabel("Mac name")
        hostField.setAccessibilityLabel("Hostname or IP address")
        portField.setAccessibilityLabel("Screen Sharing port")
        errorLabel.maximumNumberOfLines = 3
        errorLabel.lineBreakMode = .byTruncatingTail
        let form = NSGridView(views: [[label("Address"), hostField]])
        optionsForm = NSGridView(views: [
            [label("Name"), nameField],
            [label("Port"), portField]
        ])
        for grid in [form, optionsForm!] {
            grid.translatesAutoresizingMaskIntoConstraints = false
            grid.rowSpacing = 12
            grid.columnSpacing = 16
            grid.column(at: 0).width = 52
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 1).xPlacement = .fill
            for row in 0..<grid.numberOfRows { grid.row(at: row).yPlacement = .center }
        }
        optionsForm.isHidden = true
        optionsButton.bezelStyle = .inline
        optionsButton.setButtonType(.onOff)
        optionsButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        optionsButton.imagePosition = .imageLeading
        optionsButton.target = self
        optionsButton.action = #selector(toggleOptions)
        optionsButton.setAccessibilityLabel("More Options: optional name and port")
        MacLinkAppearance.primary(saveButton)
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.isEnabled = false
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        let spacer = NSView()
        let actions = stack([spacer, cancelButton, saveButton], orientation: .horizontal, spacing: 8)
        let content = stack([heading, subtitle, form, optionsButton, optionsForm, errorLabel, actions], spacing: 14)
        content.detachesHiddenViews = true
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            content.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24),
            subtitle.widthAnchor.constraint(equalTo: content.widthAnchor),
            heading.widthAnchor.constraint(equalTo: content.widthAnchor),
            form.widthAnchor.constraint(equalTo: content.widthAnchor),
            optionsForm.widthAnchor.constraint(equalTo: content.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            actions.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        window.initialFirstResponder = hostField
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func controlTextDidChange(_ obj: Notification) { validate() }
    private func validate() {
        saveButton.isEnabled = !hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func setBusy(_ busy: Bool) {
        [nameField, hostField, portField].forEach { $0.isEnabled = !busy }
        optionsButton.isEnabled = !busy
        cancelButton.isEnabled = !busy
        saveButton.isEnabled = !busy
        saveButton.title = busy ? "Saving…" : "Connect"
        if !busy { validate() }
    }
    @objc private func save() {
        guard saveButton.isEnabled else { return }
        errorLabel.stringValue = ""
        let address = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave?(name.isEmpty ? String(address.prefix(80)) : name, address, portField.stringValue)
    }
    @objc private func toggleOptions() {
        let expanded = optionsButton.state == .on
        optionsForm.isHidden = !expanded
        optionsButton.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        window?.setContentSize(NSSize(width: 460, height: expanded ? 420 : 330))
    }
    @objc private func cancel() { onCancel?() }
}

/// Automation owns policy and session actions; the shell only renders this state.
/// Coordinator callbacks and completions must be delivered on the main thread.
struct AutomationMenuState {
    var title: String = "Ready to connect"
    var detail: String = "Add a Mac to get started. Auto mode and full screen are the defaults."
    var isConfigured: Bool = false
    var isPaused: Bool = false
    var isBusy: Bool = false
}

protocol MacLinkAutomationService: AnyObject {
    var state: AutomationMenuState { get }
    var onStateChange: ((AutomationMenuState) -> Void)? { get set }
    var selectedPreference: String { get }
    func setPreference(_ preference: String)
    func start(connections: [SavedMac])
    func updateConnections(_ connections: [SavedMac])
    func togglePause()
    func showSettings(connections: [SavedMac], parentWindow: NSWindow?)
    func connect(_ connection: SavedMac, completion: @escaping (Result<Data, CLIError>) -> Void)
    func stop()
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var window: NSWindow!
    private let cli = CLIClient()
    private lazy var automation: MacLinkAutomationService = AutomationCoordinator(cli: cli)
    private lazy var native = NativeSessionCoordinator()
    private let updater = MacLinkUpdater()
    private var settingsWindow: MacLinkSettingsWindow?
    private var automationState = AutomationMenuState()
    private var automationStarted = false
    private var initialLoad = true
    private var statusItem: NSStatusItem!
    private var statusShowsScreenSharing: Bool?
    private var updateTimer: Timer?
    private let statusMenu = NSMenu()
    private var lastMenuAction: String?
    private let table = NSTableView()
    /// Apple Screen Sharing Macs; automation uses only these.
    private var connections: [SavedMac] = []
    private var rows: [ConnectionRow] = []
    private var busy = false
    private var addController: AddMacController?
    private let countLabel = label("0", size: 11, color: .secondaryLabelColor)
    private let titleLabel = label("Your Macs,\nwithin reach.", size: 34, weight: .semibold)
    private let addressLabel = label("Connect there. Work here.", size: 14, color: .secondaryLabelColor)
    private let connectionKind = label("Within reach", size: 11, weight: .semibold, color: MacLinkBrand.accent)
    private let connectionIcon = NSImageView()
    private let emptyList = label("No Macs yet.\nPair your first Mac.", size: 12, color: .secondaryLabelColor)
    private let pairButton = NSButton(title: "Pair a Mac…", target: nil, action: nil)
    private let shareButton = NSButton(title: "Share this Mac…", target: nil, action: nil)
    private let statusTitle = label("Welcome", size: 14, weight: .semibold)
    private let statusDetail = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 92))
    private let statusSymbol = NSImageView()
    private let detailsButton = NSButton(title: "Details", target: nil, action: nil)
    private var statusDetailScroll: NSScrollView?
    private var detailsExpanded = false
    private let spinner = NSProgressIndicator()
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let checkButton = NSButton(title: "Check", target: nil, action: nil)
    private let addButton = NSButton(title: "Add address", target: nil, action: nil)
    private let removeButton = NSButton(title: "", target: nil, action: nil)

    private var selectedRow: ConnectionRow? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }
    private var selectedMac: SavedMac? {
        if case .screenSharing(let mac) = selectedRow { return mac }
        return nil
    }
    private var selectedPeer: NativePeer? {
        if case .maclink(let peer) = selectedRow { return peer }
        return nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = NSImage(named: "MacLink") ?? MacLinkBrand.image(size: 512)
        buildMenu()
        buildWindow()
        buildStatusItem()
        automation.onStateChange = { [weak self] state in
            guard let self else { return }
            self.automationState = state
            self.updateControls()
        }
        automationState = automation.state
        native.onChange = { [weak self] in
            self?.updateControls()
            self?.refreshSettings()
            // A session that just ended may free a waiting update to install.
            DispatchQueue.main.async { self?.updater.installIfIdle() }
        }
        native.onPeersChange = { [weak self] in self?.rebuildRows(); self?.refreshSettings() }
        native.onVersionMismatch = { [weak self] in self?.updater.checkInBackground() }
        native.onCheckForUpdates = { [weak self] in self?.updater.checkForUpdates() }
        native.onUpdateRequest = { [weak self] in self?.updater.checkForViewer() }
        updater.onViewerStatus = { [weak self] state, ready in self?.native.reportUpdateStatus(state, ready: ready) }
        updater.willInstall = { [weak self] in self?.native.prepareForUpdateInstall() }
        updater.isIdle = { [weak self] in self?.native.isIdleForUpdate ?? false }
        updater.onChange = { [weak self] in self?.refreshStatusMenu(); self?.refreshSettings() }
        updater.start()
        // Announced from the launch self-tests: viewers may ask this Mac to update.
        native.updatesItself = updater.isAvailable
        // Sharing can stop without a session change, such as automatic sharing resuming.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.updater.installIfIdle() }
        reloadConnections()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showConnections() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { automation.stop(); native.stop() }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Open Connections", #selector(showConnections)),
                                ("Pair a Mac…", #selector(connectNative)),
                                ("Share this Mac…", #selector(shareNative))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = MacLinkBrand.menuBarImage
            button.setAccessibilityLabel("Mooring")
        }
        statusMenu.autoenablesItems = false
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        refreshStatusMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusMenu { refreshStatusMenu() }
    }

    private func refreshStatusMenu() {
        guard statusItem != nil else { return }
        statusMenu.removeAllItems()
        let heading = NSMenuItem(title: "Mooring", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        statusMenu.addItem(heading)
        let status = NSMenuItem(title: native.status ?? automationState.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.toolTip = automationState.detail
        statusMenu.addItem(status)
        let statusDescription = "Mooring — \(native.status ?? automationState.title)"
        statusItem.button?.toolTip = statusDescription
        statusItem.button?.setAccessibilityLabel(statusDescription)
        if statusShowsScreenSharing != native.isSharingScreen {
            statusShowsScreenSharing = native.isSharingScreen
            statusItem.button?.image = MacLinkBrand.menuBarImage(isSharingScreen: native.isSharingScreen)
        }
        if let lastMenuAction {
            let recent = NSMenuItem(title: lastMenuAction, action: nil, keyEquivalent: "")
            recent.isEnabled = false
            statusMenu.addItem(recent)
        }
        statusMenu.addItem(.separator())
        let available = !busy && !automationState.isBusy && addController == nil && window?.attachedSheet == nil
        MacLinkStatusMenu.addRecentMacs(native.peers, connectedPeerID: native.connectedPeerID,
                                       to: statusMenu, target: self, action: #selector(connectNativePeer(_:)),
                                       enabled: available)
        statusMenu.addItem(.separator())
        let nativeConnect = NSMenuItem(title: "Pair a Mac…", action: #selector(connectNative), keyEquivalent: "")
        nativeConnect.target = self; nativeConnect.isEnabled = available; statusMenu.addItem(nativeConnect)
        let share = NSMenuItem(title: native.isSharing ? "Sharing This Mac…" : "Share this Mac…", action: #selector(shareNative), keyEquivalent: "")
        share.target = self; statusMenu.addItem(share)
        if native.isSharing {
            let stop = NSMenuItem(title: "Stop Sharing This Mac", action: #selector(stopNativeSharing), keyEquivalent: "")
            stop.target = self; statusMenu.addItem(stop)
        }
        statusMenu.addItem(.separator())
        let connectMenuItem = NSMenuItem(title: "Apple Screen Sharing", action: nil, keyEquivalent: "")
        let connectMenu = NSMenu()
        connectMenu.autoenablesItems = false
        if connections.isEmpty {
            let empty = NSMenuItem(title: "No saved Macs", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            connectMenu.addItem(empty)
        } else {
            for mac in connections {
                let title = mac.name.count > 50 ? String(mac.name.prefix(49)) + "…" : mac.name
                let item = NSMenuItem(title: title, action: #selector(connectFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mac.id
                item.toolTip = "\(mac.name) — \(mac.endpoint)"
                item.isEnabled = available
                connectMenu.addItem(item)
            }
        }
        connectMenuItem.submenu = connectMenu
        connectMenuItem.isEnabled = !connections.isEmpty && available
        statusMenu.addItem(connectMenuItem)
        let openItem = NSMenuItem(title: "Your Macs…", action: #selector(showConnections), keyEquivalent: "o")
        openItem.target = self
        statusMenu.addItem(openItem)
        let addItem = NSMenuItem(title: "Add Mac…", action: #selector(addMac), keyEquivalent: "n")
        addItem.target = self
        addItem.isEnabled = available
        statusMenu.addItem(addItem)
        statusMenu.addItem(.separator())
        if automationState.isConfigured && !AppleSession.isTrusted {
            let permission = NSMenuItem(title: "Enable Full Screen & Auto Switching…", action: #selector(enableSessionControl), keyEquivalent: "")
            permission.target = self
            permission.isEnabled = available
            statusMenu.addItem(permission)
        }
        let pauseItem = NSMenuItem(title: automationState.isPaused ? "Resume Automation" : "Pause Automation",
                                   action: #selector(toggleAutomation), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.isEnabled = automationState.isConfigured
        statusMenu.addItem(pauseItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        settings.toolTip = "Sharing, viewing, paired Macs and updates."
        statusMenu.addItem(settings)
        // Version and updates sit together, just above Quit.
        statusMenu.addItem(.separator())
        let release = Bundle.main.object(forInfoDictionaryKey: "MacLinkReleaseVersion") as? String ?? "development"
        let version = NSMenuItem(title: "Version \(release)", action: nil, keyEquivalent: "")
        version.isEnabled = false; statusMenu.addItem(version)
        if let ready = updater.readyVersion {
            let install = NSMenuItem(title: "Install Update \(ready) & Relaunch", action: #selector(installUpdate), keyEquivalent: "")
            install.target = self; install.toolTip = "Installs now. Otherwise it installs automatically when no session is connected."
            statusMenu.addItem(install)
        } else if updater.isAvailable {
            let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            check.target = self; statusMenu.addItem(check)
        }
        statusMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Mooring", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        statusMenu.addItem(quit)
    }

    @objc private func connectNative() { native.showConnect() }
    @objc private func shareNative() { native.showShare() }
    @objc private func stopNativeSharing() { native.stopSharingByUser() }
    @objc private func checkForUpdates() { updater.checkForUpdates() }
    @objc private func installUpdate() { updater.install() }

    @objc private func connectNativePeer(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { native.connect(peerID: id) }
    }

    @objc private func showConnections() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func connectFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let row = rows.firstIndex(where: { $0.id == ConnectionRow.screenSharingID(id) }),
              !busy, !automationState.isBusy, window.attachedSheet == nil else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        connect()
    }

    @objc private func toggleAutomation() {
        guard automationState.isConfigured else { return }
        automation.togglePause()
    }

    @objc private func enableSessionControl() { AppleSession.requestPermission() }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Mooring", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Mooring", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.option, .command]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Mooring", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu(title: "File")
        file.submenu!.addItem(withTitle: "Pair a Mac…", action: #selector(connectNative), keyEquivalent: "k")
        file.submenu!.addItem(withTitle: "Share this Mac…", action: #selector(shareNative), keyEquivalent: "")
        file.submenu!.addItem(.separator())
        file.submenu!.addItem(withTitle: "Your Macs…", action: #selector(showConnections), keyEquivalent: "o")
        file.submenu!.addItem(withTitle: "Add Mac…", action: #selector(addMac), keyEquivalent: "n")
        file.submenu!.addItem(withTitle: "Connect", action: #selector(connect), keyEquivalent: "\r")
        file.submenu!.addItem(withTitle: "Check", action: #selector(checkConnection), keyEquivalent: "r")
        file.submenu!.addItem(.separator())
        file.submenu!.addItem(withTitle: "Remove Saved Mac…", action: #selector(removeMac), keyEquivalent: "")
        file.submenu!.addItem(.separator())
        file.submenu!.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        menu.addItem(file)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        for (name, selector, key) in [("Undo", Selector(("undo:")), "z"),
                                       ("Cut", #selector(NSText.cut(_:)), "x"),
                                       ("Copy", #selector(NSText.copy(_:)), "c"),
                                       ("Paste", #selector(NSText.paste(_:)), "v"),
                                       ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.submenu!.addItem(withTitle: name, action: selector, keyEquivalent: key)
        }
        menu.addItem(edit)
        // ⌃⌘F stays on this Mac while a viewer captures shortcuts; without a
        // menu item to take it, the viewer would send it to the remote Mac.
        let view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        view.submenu = NSMenu(title: "View")
        view.submenu!.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        view.submenu!.items[0].keyEquivalentModifierMask = [.control, .command]
        view.submenu!.addItem(.separator())
        for (title, action, key) in [
            ("Diagnostic Footer", #selector(NativeViewerWindow.toggleDiagnosticBar(_:)), "d"),
            ("Stats for Nerds", #selector(NativeViewerWindow.toggleStatsForNerds(_:)), "i")
        ] {
            let item = view.submenu!.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.control, .command]
        }
        view.submenu!.addItem(withTitle: "Save Session Diagnostics…", action: #selector(NativeViewerWindow.saveDiagnostics(_:)), keyEquivalent: "")
        menu.addItem(view)
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(.separator())
        windows.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windows
        menu.addItem(windowItem)
        NSApp.windowsMenu = windows
        let help = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        help.submenu = NSMenu(title: "Help")
        help.submenu!.addItem(withTitle: "Connecting to a Mac", action: #selector(showConnectionHelp), keyEquivalent: "?")
        menu.addItem(help)
        for submenu in [appMenu, file.submenu!, help.submenu!] {
            for item in submenu.items where item.action == #selector(showAbout) || item.action == #selector(showSettings)
                || item.action == #selector(addMac) || item.action == #selector(connect)
                || item.action == #selector(checkConnection) || item.action == #selector(removeMac)
                || item.action == #selector(connectNative) || item.action == #selector(shareNative)
                || item.action == #selector(showConnections) || item.action == #selector(showConnectionHelp) {
                item.target = self
            }
        }
        NSApp.mainMenu = menu
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Mooring"
        MacLinkAppearance.prepare(window)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 610)
        window.setFrameAutosaveName("MacLinkMainWindow")
        window.center()
        let root = window.contentView!
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let main = NSView()
        main.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        root.addSubview(divider)
        root.addSubview(main)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 250),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            main.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let brandIcon = NSImageView(image: MacLinkBrand.image(size: 36))
        brandIcon.translatesAutoresizingMaskIntoConstraints = false
        brandIcon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        brandIcon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let brand = stack([brandIcon, stack([label("mooring", size: 21, weight: .semibold),
                                           label(MacLinkBrand.tagline, size: 10, color: .secondaryLabelColor)], spacing: 2)],
                          orientation: .horizontal, spacing: 9)
        sidebar.addSubview(brand)
        let heading = stack([label("Macs", size: 12, weight: .semibold), NSView(), countLabel], orientation: .horizontal)
        sidebar.addSubview(heading)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 58
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.focusRingType = .default
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(connect)
        table.target = self
        table.setAccessibilityLabel("Saved Macs")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mac"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        sidebar.addSubview(scroll)
        emptyList.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(emptyList)
        addButton.bezelStyle = .rounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.target = self
        addButton.action = #selector(addMac)
        removeButton.bezelStyle = .rounded
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove saved Mac")
        removeButton.toolTip = "Remove the selected Mac from this list"
        removeButton.setAccessibilityLabel("Remove selected Mac")
        removeButton.target = self
        removeButton.action = #selector(removeMac)
        let sidebarActions = stack([addButton, NSView(), removeButton], orientation: .horizontal, spacing: 8)
        sidebar.addSubview(sidebarActions)
        let settings = NSButton(title: "Settings…", target: self, action: #selector(showSettings))
        settings.bezelStyle = .inline
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settings.imagePosition = .imageLeading
        let sidebarFooter = stack([settings, NSView()], orientation: .horizontal)
        sidebar.addSubview(sidebarFooter)
        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            brand.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -18),
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24),
            heading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20),
            heading.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 32),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: sidebarActions.topAnchor, constant: -16),
            sidebarActions.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            sidebarActions.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            sidebarActions.bottomAnchor.constraint(equalTo: sidebarFooter.topAnchor, constant: -18),
            sidebarFooter.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            sidebarFooter.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20),
            sidebarFooter.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20),
            emptyList.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 18),
            emptyList.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            emptyList.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20)
        ])
        let icon = connectionIcon
        icon.image = MacLinkBrand.image(size: 64)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 64), icon.heightAnchor.constraint(equalToConstant: 64)])
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        addressLabel.maximumNumberOfLines = 1
        addressLabel.lineBreakMode = .byTruncatingMiddle
        statusTitle.maximumNumberOfLines = 1
        statusTitle.lineBreakMode = .byTruncatingTail
        let intro = stack([icon, connectionKind, titleLabel, addressLabel], spacing: 10)
        let statusBox = MacLinkSurface()
        statusBox.translatesAutoresizingMaskIntoConstraints = false
        statusSymbol.translatesAutoresizingMaskIntoConstraints = false
        statusSymbol.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        statusSymbol.contentTintColor = .secondaryLabelColor
        statusDetail.isEditable = false
        statusDetail.isSelectable = true
        statusDetail.drawsBackground = false
        statusDetail.font = .systemFont(ofSize: 13)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.isHorizontallyResizable = false
        statusDetail.isVerticallyResizable = true
        statusDetail.textContainerInset = .zero
        statusDetail.textContainer?.lineFragmentPadding = 0
        statusDetail.textContainer?.widthTracksTextView = true
        statusDetail.autoresizingMask = [.width]
        statusDetail.setAccessibilityLabel("Connection status details")
        let detailScroll = NSScrollView()
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.drawsBackground = false
        detailScroll.borderType = .noBorder
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.documentView = statusDetail
        statusDetailScroll = detailScroll
        detailScroll.isHidden = true
        detailsButton.bezelStyle = .rounded
        detailsButton.setButtonType(.onOff)
        detailsButton.target = self
        detailsButton.action = #selector(toggleDetails)
        detailsButton.setAccessibilityLabel("Show connection details")
        let detailHeight = detailScroll.heightAnchor.constraint(equalToConstant: 92)
        detailHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            detailHeight,
            detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            detailScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 120)
        ])
        let statusHeading = stack([statusTitle, NSView(), detailsButton], orientation: .horizontal, spacing: 12)
        let statusCopy = stack([statusHeading, detailScroll], spacing: 10)
        statusCopy.detachesHiddenViews = true
        statusHeading.widthAnchor.constraint(equalTo: statusCopy.widthAnchor).isActive = true
        let statusRow = stack([statusSymbol, statusCopy], orientation: .horizontal, spacing: 12)
        statusRow.alignment = .top
        statusBox.addSubview(statusRow)
        NSLayoutConstraint.activate([
            statusSymbol.widthAnchor.constraint(equalToConstant: 18),
            statusSymbol.heightAnchor.constraint(equalToConstant: 20),
            statusRow.leadingAnchor.constraint(equalTo: statusBox.leadingAnchor, constant: 18),
            statusRow.trailingAnchor.constraint(equalTo: statusBox.trailingAnchor, constant: -18),
            statusRow.topAnchor.constraint(equalTo: statusBox.topAnchor, constant: 18),
            statusRow.bottomAnchor.constraint(equalTo: statusBox.bottomAnchor, constant: -18),
            detailScroll.widthAnchor.constraint(equalTo: statusCopy.widthAnchor)
        ])
        MacLinkAppearance.primary(connectButton)
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.setAccessibilityLabel("Connect to selected Mac using Apple Screen Sharing")
        checkButton.bezelStyle = .rounded
        checkButton.controlSize = .large
        checkButton.target = self
        checkButton.action = #selector(checkConnection)
        checkButton.toolTip = "Check the network connection and Screen Sharing protocol without signing in"
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let buttons = stack([connectButton, checkButton, spinner], orientation: .horizontal, spacing: 10)
        connectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        let content = stack([intro, buttons, statusBox], spacing: 28)
        main.addSubview(content)
        for (button, action, symbol) in [(pairButton, #selector(connectNative), "link"),
                                        (shareButton, #selector(shareNative), "rectangle.on.rectangle")] {
            button.bezelStyle = .rounded
            button.target = self; button.action = action
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        pairButton.toolTip = "Pair with your other Mac’s code. ⌘K"
        shareButton.toolTip = "Let your paired Macs connect here."
        let topBar = stack([label("Workspace", size: 13, weight: .semibold), NSView(), pairButton, shareButton], orientation: .horizontal, spacing: 10)
        main.addSubview(topBar)
        let hint = label("Remote desktop for Mac", size: 12, color: .secondaryLabelColor)
        let help = NSButton(image: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Connection help and display mode")!, target: self, action: #selector(showConnectionHelp))
        help.isBordered = false
        help.toolTip = "Connection help and display mode"
        let footer = stack([hint, NSView(), help], orientation: .horizontal, spacing: 10)
        main.addSubview(footer)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 36),
            content.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -36),
            content.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 28),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topBar.topAnchor.constraint(equalTo: main.topAnchor, constant: 24),
            intro.widthAnchor.constraint(equalTo: content.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: intro.widthAnchor),
            addressLabel.widthAnchor.constraint(equalTo: intro.widthAnchor),
            statusBox.widthAnchor.constraint(equalTo: content.widthAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -26),
            footer.topAnchor.constraint(greaterThanOrEqualTo: content.bottomAnchor, constant: 24)
        ])
        updateControls()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = MacCell(), item = rows[row]
        cell.nameLabel.stringValue = item.name
        cell.hostLabel.stringValue = item.detail
        cell.symbol.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        cell.setAccessibilityLabel("\(item.name), \(item.detail)")
        return cell
    }

    /// MacLink pairings first, then Apple Screen Sharing Macs. Keeps the
    /// selection when the same entry is still present.
    private func rebuildRows(select id: String? = nil) {
        let selection = id ?? selectedRow?.id
        rows = native.peers.map(ConnectionRow.maclink) + connections.map(ConnectionRow.screenSharing)
        countLabel.stringValue = String(rows.count)
        emptyList.isHidden = !rows.isEmpty
        table.reloadData()
        if let row = rows.firstIndex(where: { $0.id == selection }) ?? (rows.isEmpty ? nil : 0) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        updateSelection()
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !busy && !automationState.isBusy && addController == nil }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private func updateSelection() {
        connectionKind.isHidden = selectedRow == nil
        if let peer = selectedPeer {
            connectionKind.stringValue = "Paired"
            connectionIcon.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: nil)
            connectionIcon.contentTintColor = MacLinkBrand.accent
            titleLabel.stringValue = peer.name
            titleLabel.toolTip = peer.name
            addressLabel.stringValue = "Paired · " + peer.address
            addressLabel.toolTip = peer.address
            setStatus("Ready", "On \(peer.name), open Mooring → Share this Mac → Start sharing.")
        } else if let mac = selectedMac {
            connectionKind.stringValue = "Screen Sharing"
            connectionIcon.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
            connectionIcon.contentTintColor = MacLinkBrand.accent
            titleLabel.stringValue = mac.name
            titleLabel.toolTip = mac.name
            addressLabel.stringValue = mac.endpoint
            addressLabel.toolTip = mac.endpoint
            setStatus("Ready", "Sign in with this Mac’s account after connecting.")
        } else {
            connectionKind.stringValue = "Within reach"
            connectionIcon.image = MacLinkBrand.image(size: 64)
            connectionIcon.contentTintColor = nil
            titleLabel.stringValue = "Your Macs,\nwithin reach."
            titleLabel.toolTip = nil
            addressLabel.stringValue = "Connect there. Work here."
            addressLabel.toolTip = nil
            setStatus("Pair once. Return anytime.", "On your other Mac, open Mooring → Share this Mac. Start sharing and copy its code.\n\nFor Apple Screen Sharing, use an address.")
        }
        updateControls()
    }

    private func setStatus(_ title: String, _ detail: String, error: Bool = false, success: Bool = false) {
        statusTitle.stringValue = title
        statusTitle.toolTip = title
        statusDetail.string = detail
        statusDetail.scrollRangeToVisible(NSRange(location: 0, length: 0))
        statusSymbol.image = NSImage(systemSymbolName: error ? "exclamationmark.circle" : success ? "checkmark.circle" : "info.circle", accessibilityDescription: nil)
        statusSymbol.contentTintColor = error ? .systemRed : success ? .systemGreen : .secondaryLabelColor
        statusTitle.textColor = error ? .systemRed : .labelColor
        if error { detailsExpanded = true }
        renderDetails()
        NSAccessibility.post(element: statusTitle, notification: .valueChanged)
    }

    @objc private func toggleDetails() {
        detailsExpanded = detailsButton.state == .on
        renderDetails()
    }

    private func renderDetails() {
        statusDetailScroll?.isHidden = !detailsExpanded
        detailsButton.state = detailsExpanded ? .on : .off
        detailsButton.title = "Details"
        detailsButton.setAccessibilityLabel(detailsExpanded ? "Hide connection details" : "Show connection details")
    }

    private func setBusy(_ value: Bool) {
        busy = value
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        updateControls()
    }

    private func updateControls() {
        let available = !busy && !automationState.isBusy && addController == nil && window?.attachedSheet == nil
        connectButton.isEnabled = available
        connectButton.action = selectedRow == nil ? #selector(connectNative) : #selector(connect)
        connectButton.title = busy ? "Connecting…" : selectedRow == nil ? "Pair a Mac…" : (selectedPeer.map { $0.id == native.connectedPeerID } ?? false) ? "Return" : "Connect"
        connectButton.setAccessibilityLabel(selectedRow == nil ? "Pair a Mac using a Mooring code" : "Connect to \(selectedRow?.name ?? "Mac")")
        checkButton.isHidden = selectedPeer != nil
        checkButton.title = selectedRow == nil ? "Use an address…" : "Check"
        checkButton.action = selectedRow == nil ? #selector(addMac) : #selector(checkConnection)
        checkButton.toolTip = selectedRow == nil ? "Add a hostname or IP address for Apple Screen Sharing." : "Check TCP reachability and the Screen Sharing greeting without signing in."
        checkButton.isEnabled = available && (selectedRow == nil || selectedMac != nil)
        pairButton.isHidden = selectedRow == nil
        pairButton.isEnabled = available
        shareButton.isEnabled = available
        shareButton.title = native.isSharing ? "Sharing this Mac…" : "Share this Mac…"
        removeButton.isEnabled = available && selectedRow != nil
        addButton.isEnabled = available
        refreshStatusMenu()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showConnections) { return true }
        if menuItem.action == #selector(showSettings) { return true }
        if [#selector(connectNative), #selector(shareNative)].contains(menuItem.action) {
            return !busy && !automationState.isBusy && addController == nil && window.attachedSheet == nil
        }
        if menuItem.action == #selector(addMac) {
            return !busy && !automationState.isBusy && addController == nil && window.attachedSheet == nil
        }
        if [#selector(connect), #selector(removeMac)].contains(menuItem.action) {
            return !busy && !automationState.isBusy && selectedRow != nil && window.attachedSheet == nil
        }
        if menuItem.action == #selector(checkConnection) {
            return !busy && !automationState.isBusy && selectedMac != nil && window.attachedSheet == nil
        }
        return window?.attachedSheet == nil
    }

    /// `id` selects a saved Screen Sharing Mac by its store ID.
    private func reloadConnections(select id: String? = nil, onLoaded: (() -> Void)? = nil) {
        let selection = id.map(ConnectionRow.screenSharingID) ?? selectedRow?.id
        setBusy(true)
        cli.run(["list"]) { [weak self] result in
            guard let self else { return }
            self.setBusy(false)
            switch result {
            case .failure(let error):
                self.rebuildRows()
                self.setStatus("Couldn’t load saved Macs", error.message, error: true)
                self.lastMenuAction = "Couldn’t load saved Macs"
                self.showConnections()
                self.refreshStatusMenu()
            case .success(let data):
                do {
                    self.connections = try JSONDecoder().decode([SavedMac].self, from: data)
                    self.rebuildRows(select: selection)
                    if self.automationStarted {
                        self.automation.updateConnections(self.connections)
                    } else {
                        self.automationStarted = true
                        self.automation.start(connections: self.connections)
                    }
                    if self.initialLoad && self.rows.isEmpty { self.showConnections() }
                    self.initialLoad = false
                    onLoaded?()
                } catch {
                    self.setStatus("Couldn’t read saved Macs", "The Mooring command-line tool returned an unexpected response. \(error.localizedDescription)", error: true)
                    self.lastMenuAction = "Couldn’t read saved Macs"
                    self.showConnections()
                    self.refreshStatusMenu()
                }
            }
        }
    }

    @objc private func addMac() {
        guard !busy, !automationState.isBusy, addController == nil, window.attachedSheet == nil else { return }
        showConnections()
        let controller = AddMacController()
        addController = controller
        controller.onCancel = { [weak self] in self?.closeAddSheet() }
        controller.onSave = { [weak self, weak controller] name, host, port in
            guard let self, let controller, !self.busy else { return }
            let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
            guard portText.isEmpty || (UInt16(portText).map { $0 > 0 } ?? false) else {
                controller.errorLabel.stringValue = "Enter a port between 1 and 65535. The default is 5900."
                return
            }
            self.setBusy(true)
            controller.setBusy(true)
            self.cli.run(["add", "--name", name.trimmingCharacters(in: .whitespacesAndNewlines),
                          "--host", host.trimmingCharacters(in: .whitespacesAndNewlines),
                          "--port", portText.isEmpty ? "5900" : portText]) { [weak self, weak controller] result in
                guard let self, let controller else { return }
                self.setBusy(false)
                controller.setBusy(false)
                switch result {
                case .failure(let error):
                    controller.errorLabel.stringValue = error.message
                    controller.errorLabel.toolTip = error.message
                case .success(let data):
                    do {
                        let saved = try JSONDecoder().decode(SavedMac.self, from: data)
                        self.closeAddSheet()
                        self.reloadConnections(select: saved.id) { [weak self] in
                            guard let self, self.selectedMac?.id == saved.id else { return }
                            self.connect()
                        }
                    } catch {
                        // The write may have succeeded; refresh instead of inviting a duplicate save.
                        self.closeAddSheet()
                        self.reloadConnections()
                    }
                }
            }
        }
        window.beginSheet(controller.window!)
        updateControls()
    }

    private func closeAddSheet() {
        guard let sheet = addController?.window else { return }
        window.endSheet(sheet)
        addController = nil
        updateControls()
    }

    @objc private func removeMac() {
        guard !busy, !automationState.isBusy, window.attachedSheet == nil else { return }
        if let peer = selectedPeer { forgetPairing(peer); return }
        guard let mac = selectedMac else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(mac.name)?"
        alert.informativeText = "Remove this saved address? You can add it again."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.updateControls()
            guard response == .alertFirstButtonReturn else { return }
            self.setBusy(true)
            self.cli.run(["remove", mac.id]) { [weak self] result in
                guard let self else { return }
                self.setBusy(false)
                switch result {
                case .failure(let error): self.setStatus("Couldn’t remove this Mac", error.message, error: true)
                case .success: self.reloadConnections()
                }
            }
        }
        updateControls()
    }

    private func forgetPairing(_ peer: NativePeer) {
        let alert = NSAlert()
        alert.messageText = "Forget \(peer.name)?"
        alert.informativeText = "This removes the pairing and its secret from this Mac. To connect again, copy a new pairing code from \(peer.name)."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.updateControls()
            guard response == .alertFirstButtonReturn else { return }
            do { try self.native.forget(peerID: peer.id) }
            catch { self.setStatus("Couldn’t forget this Mac", error.localizedDescription, error: true) }
        }
        updateControls()
    }

    @objc private func connect() {
        guard !busy, !automationState.isBusy, window.attachedSheet == nil else { return }
        if let peer = selectedPeer {
            lastMenuAction = "Connecting to \(peer.name.prefix(40))…"
            setStatus("Connecting…", "Connecting to \(peer.name). If it does not open, make sure \(peer.name) is sharing.")
            native.connect(peerID: peer.id)
            refreshStatusMenu()
            return
        }
        guard let mac = selectedMac else { return }
        lastMenuAction = "Opening \(mac.name.prefix(40))…"
        setBusy(true)
        setStatus("Opening Screen Sharing…", "Preparing a connection to \(mac.name).")
        automation.connect(mac) { [weak self] result in
            guard let self else { return }
            self.setBusy(false)
            switch result {
            case .failure(let error):
                self.lastMenuAction = "Couldn’t open Screen Sharing"
                self.setStatus("Couldn’t open Screen Sharing", error.message, error: true)
                self.showConnections()
            case .success:
                self.lastMenuAction = "Screen Sharing opened"
                self.setStatus("Screen Sharing opened", "Sign in with your remote Mac’s account if asked. Connection status and Pause are in the Mooring menu.", success: true)
            }
            self.refreshStatusMenu()
        }
    }

    @objc private func checkConnection() {
        guard !busy, !automationState.isBusy, window.attachedSheet == nil, let mac = selectedMac else { return }
        setBusy(true)
        setStatus("Checking \(mac.name)…", "Testing the address and Screen Sharing service. This does not sign in.")
        cli.run(["inspect", mac.id], timeout: 20) { [weak self] result in
            guard let self else { return }
            self.setBusy(false)
            switch result {
            case .failure(let error): self.setStatus("Connection check failed", error.message, error: true)
            case .success(let data):
                do {
                    let inspection = try JSONDecoder().decode(HostInspection.self, from: data)
                    var lines: [String] = []
                    if let milliseconds = inspection.tcp_connect_ms {
                        lines.append("TCP connection established in \(String(format: "%.1f", milliseconds)) ms. This is not display latency.")
                    }
                    if let version = inspection.rfb_version { lines.append("Screen Sharing banner: \(version.trimmingCharacters(in: .whitespacesAndNewlines)).") }
                    if let note = inspection.note, !note.isEmpty { lines.append(note) }
                    self.setStatus("Connection check complete", lines.isEmpty ? "The host check completed. Connect to sign in with Apple Screen Sharing." : lines.joined(separator: "\n"), success: true)
                } catch {
                    self.setStatus("Unexpected check response", "The Mooring command-line tool returned data this app could not read. \(error.localizedDescription)", error: true)
                }
            }
        }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let controller = MacLinkSettingsWindow()
            controller.onChange = { [weak self] setting, on in self?.changeSetting(setting, on) }
            controller.onRemovePeer = { [weak self] peer in
                guard let self else { return }
                do { try self.native.forget(peerID: peer.id) } catch { self.showSettingsError(error.localizedDescription) }
                self.refreshSettings()
            }
            controller.onRemoveDevice = { [weak self] device in
                guard let self else { return }
                do { try self.native.removeDevice(device.id) } catch { self.showSettingsError(error.localizedDescription) }
                self.refreshSettings()
            }
            controller.onStopOldCode = { [weak self] in
                guard let self else { return }
                do { try self.native.stopOldCode() } catch { self.showSettingsError(error.localizedDescription) }
                self.refreshSettings()
            }
            controller.onExtendOldCode = { [weak self] in
                guard let self else { return }
                do { try self.native.extendOldCode() } catch { self.showSettingsError(error.localizedDescription) }
                self.refreshSettings()
            }
            controller.onShareThisMac = { [weak self] in self?.native.showShare() }
            controller.onAllowKeyboardAndMouse = { [weak self] in self?.native.allowKeyboardAndMouse() }
            controller.onCheckForUpdates = { [weak self] in self?.updater.checkForUpdates() }
            controller.onInstallUpdate = { [weak self] in self?.updater.install() }
            controller.onAutomationSettings = { [weak self] in self?.showAutomationSettings() }
            // Permissions and login approval change in System Settings.
            controller.onAppear = { [weak self] in self?.refreshSettings() }
            settingsWindow = controller
            controller.window?.center()
        }
        refreshSettings()
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Apple Screen Sharing automation keeps its own Save and Cancel window.
    private func showAutomationSettings() {
        guard !busy, !automationState.isBusy, window.attachedSheet == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        automation.showSettings(connections: connections, parentWindow: window.isVisible ? window : nil)
        updateControls()
    }

    private func refreshSettings() {
        guard let settingsWindow else { return }
        var state = MacLinkSettingsState()
        state.sharesAutomatically = native.sharesAutomatically
        state.sharesClipboard = native.sharesClipboard
        state.keyboardAndMouseAllowed = native.keyboardAndMouseAllowed
        let approved = native.approvedDevices()
        state.devices = approved?.devices
        state.legacy = approved?.legacy ?? NativeLegacyState()
        state.connectedDeviceID = native.connectedDeviceID
        state.matchesScreen = native.matchesScreen
        state.playsSound = native.playsSound
        state.lowersDisplayLatency = native.lowersDisplayLatency
        state.showsDiagnosticBar = native.showsDiagnosticBar
        let login = SMAppService.mainApp.status
        state.launchesAtLogin = login == .enabled || login == .requiresApproval
        state.loginNeedsApproval = login == .requiresApproval
        state.peers = native.peers
        state.connectedPeerID = native.connectedPeerID
        let local = NativeVersion.local
        state.version = "\(local.release == 0 ? (Bundle.main.object(forInfoDictionaryKey: "MacLinkReleaseVersion") as? String ?? "development") : local.name) (build \(local.build))"
        if let ready = updater.readyVersion { state.updates = .ready(updater.readyNativeVersion?.name ?? ready) }
        else { state.updates = updater.isAvailable ? .available : .unavailable }
        settingsWindow.show(state)
    }

    private func changeSetting(_ setting: MacLinkSetting, _ on: Bool) {
        switch setting {
        case .sharesAutomatically: native.setSharingAutomatically(on)
        case .sharesClipboard: native.sharesClipboard = on
        case .matchesScreen: native.matchesScreen = on
        case .playsSound: native.playsSound = on
        case .lowersDisplayLatency: native.lowersDisplayLatency = on
        case .showsDiagnosticBar: native.showsDiagnosticBar = on
        case .launchesAtLogin:
            do {
                let status = SMAppService.mainApp.status
                if on && status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() }
                else if !on && (status == .enabled || status == .requiresApproval) { try SMAppService.mainApp.unregister() }
            } catch { showSettingsError("Mooring couldn't change launching at login: \(error.localizedDescription)") }
        }
        refreshSettings()
    }

    private func showSettingsError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Mooring Settings"; alert.informativeText = message
        if let window = settingsWindow?.window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @objc private func showConnectionHelp() {
        guard window.attachedSheet == nil else { return }
        showConnections()
        let alert = NSAlert()
        alert.messageText = "Connecting to a Mac"
        alert.informativeText = "Pair: on your other Mac, open Mooring → Share this Mac. Start sharing, copy a code, then paste it into Pair a Mac here.\n\nScreen Sharing: enable it in System Settings → General → Sharing on the other Mac. Use an address here. Apple handles your password.\n\nMooring stays in the menu bar when you close this window. Display and automation options are in Settings."
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window) { [weak self] _ in self?.updateControls() }
        updateControls()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Mooring",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "MacLinkReleaseVersion") as? String ?? "Development",
            .applicationIcon: MacLinkBrand.image(size: 128),
            .credits: NSAttributedString(string: "Your Macs, within reach.\nFormerly MacLink.")
        ])
    }
}

@main
private enum MacLinkMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
