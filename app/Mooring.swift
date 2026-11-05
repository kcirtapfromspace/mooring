import AppKit
import Foundation
import Darwin
import ServiceManagement

struct SavedMac: Decodable {
    struct SSHHop: Decodable { let target: String }
    let id: String
    let name: String
    /// With `ssh`, the VNC address as seen from the SSH host.
    let host: String
    let port: UInt16
    /// "vnc" for a VNC server such as wayvnc on Linux. "mac", or no value in
    /// older saves, marks an address saved for Apple Screen Sharing, which
    /// Mooring no longer opens; it is kept so the person can pair or remove it.
    let server: String?
    let ssh: SSHHop?

    var isMac: Bool { (server ?? "mac") == "mac" }
    /// Mooring's own viewer opens VNC servers that are not Macs, through SSH.
    var opensInMooring: Bool { !isMac && ssh != nil }

    var endpoint: String {
        let address = host.contains(":") ? "[\(host)]" : host
        let direct = port == 5900 ? host : "\(address):\(port)"
        guard let ssh else { return direct }
        return host == "127.0.0.1" && port == 5900 ? "via SSH \(ssh.target)" : "\(direct) via SSH \(ssh.target)"
    }
}

private struct HostInspection: Decodable {
    let host: String
    let port: UInt16
    let tcp_connect_ms: Double?
    let rfb_version: String?
    let note: String?
    /// SSH connections to other VNC servers: whether the desktop is locked.
    let desktop: DesktopReport?
    let desktop_error: DesktopError?
}

/// Rust decides the wording; the app only shows it.
private struct DesktopReport: Decodable {
    let lock: String
    let title: String
    let message: String
    let notes: [String]?
}

private struct DesktopError: Decodable {
    let message: String
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

    func executableURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["MOORING_BIN"], !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw CLIError(message: "MOORING_BIN does not point to an executable: \(override)")
            }
            return URL(fileURLWithPath: override)
        }
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("mooring"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mooring")
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CLIError(message: "The Mooring command-line tool is missing. Rebuild the app with scripts/build-app.sh.")
        }
        return url
    }

    private func execute(_ arguments: [String], timeout: TimeInterval) throws -> Data {
        let binary = try executableURL()
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("mooring-\(UUID().uuidString)")
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
    let view = MooringPrivacyLabel(labelWithString: "")
    view.stringValue = text
    view.observePrivacy()
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

/// One row of the Connections list: a Mac paired for a Mooring session, or a
/// connection saved by the CLI store (a Linux desktop reached through SSH, or
/// an address left from Apple Screen Sharing, which now needs pairing).
private enum ConnectionRow {
    case saved(SavedMac)
    case mooring(NativePeer)

    static func savedID(_ id: String) -> String { "saved:" + id }
    var id: String {
        switch self {
        case .saved(let mac): return Self.savedID(mac.id)
        case .mooring(let peer): return "mooring:" + peer.id
        }
    }
    var name: String {
        switch self {
        case .saved(let mac): return mac.name
        case .mooring(let peer): return peer.name
        }
    }
    var detail: String {
        switch self {
        case .saved(let mac) where mac.opensInMooring: return "Linux · " + mac.endpoint
        case .saved(let mac) where mac.isMac: return "Needs pairing · " + mac.endpoint
        case .saved(let mac): return "Needs SSH · " + mac.endpoint
        case .mooring(let peer): return "Paired · " + peer.address
        }
    }
    var symbol: String {
        switch self {
        case .saved(let mac): return mac.opensInMooring ? "display" : "exclamationmark.triangle"
        case .mooring: return "bolt.horizontal.circle"
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
    let nameField: NSTextField = MooringPrivacy.isEnabled ? NSSecureTextField(string: "") : NSTextField(string: "")
    let hostField: NSTextField = MooringPrivacy.isEnabled ? NSSecureTextField(string: "") : NSTextField(string: "")
    let portField = NSTextField(string: "5900")
    let sshField: NSTextField = MooringPrivacy.isEnabled ? NSSecureTextField(string: "") : NSTextField(string: "")
    let errorLabel = label("", size: 12, color: .systemRed)
    let saveButton = NSButton(title: "Connect", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let optionsButton = NSButton(title: "Options", target: nil, action: nil)
    private var optionsForm: NSGridView!
    /// Name, VNC address on the SSH host (may be empty), port, SSH target, server ("vnc").
    var onSave: ((String, String, String, String, String) -> Void)?
    var onCancel: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Add a Linux Desktop"
        MooringAppearance.prepare(window)
        let heading = MooringAppearance.header("Add a Linux Desktop", subtitle: "Opens in Mooring through SSH.")
        let subtitle = label("Run a VNC server such as wayvnc there. Enter how you reach it with SSH. Macs pair instead: Pair a Mac.", color: .secondaryLabelColor)
        for field in [nameField, hostField, portField, sshField] {
            field.delegate = self
            field.controlSize = .large
        }
        nameField.placeholderString = "Optional"
        hostField.placeholderString = "127.0.0.1 on the SSH host"
        nameField.setAccessibilityLabel("Desktop name")
        hostField.setAccessibilityLabel("VNC address as seen from the SSH host")
        portField.setAccessibilityLabel("VNC port")
        sshField.placeholderString = "An ~/.ssh/config alias or user@host"
        sshField.setAccessibilityLabel("SSH target")
        sshField.toolTip = "SSH uses your keys and agent and never asks for a password. You sign in to the desktop itself when you connect."
        errorLabel.maximumNumberOfLines = 3
        errorLabel.lineBreakMode = .byTruncatingTail
        let form = NSGridView(views: [[label("SSH"), sshField]])
        optionsForm = NSGridView(views: [
            [label("Name"), nameField],
            [label("Address"), hostField],
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
        optionsButton.setAccessibilityLabel("More Options: optional name, VNC address and port")
        MooringAppearance.primary(saveButton)
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
        window.initialFirstResponder = sshField
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func controlTextDidChange(_ obj: Notification) { validate() }
    private func validate() {
        let ssh = sshField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        saveButton.isEnabled = !ssh.isEmpty
    }
    func setBusy(_ busy: Bool) {
        [nameField, hostField, portField, sshField].forEach { $0.isEnabled = !busy }
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
        let ssh = sshField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave?(name.isEmpty ? String(ssh.prefix(80)) : name, address, portField.stringValue, ssh, "vnc")
    }
    @objc private func toggleOptions() {
        let expanded = optionsButton.state == .on
        optionsForm.isHidden = !expanded
        optionsButton.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        window?.setContentSize(NSSize(width: 460, height: expanded ? 450 : 330))
    }
    @objc private func cancel() { onCancel?() }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var window: NSWindow!
    private let cli = CLIClient()
    private let tunnels = SSHTunnels()
    /// Mooring's own viewers for VNC servers that are not Macs, by connection ID.
    private var vncViewers: [String: VNCViewerWindow] = [:]
    /// Tunnels that are ready and waiting for the sign-in prompt: local port.
    private var vncPending: [String: UInt16] = [:]
    /// The latest read-only desktop check per connection: user, title, message.
    private var desktopStates: [String: (user: String?, title: String, message: String)] = [:]
    private var tunnelEnded = Set<String>()
    private lazy var native = NativeSessionCoordinator()
    private let updater = MooringUpdater()
    private var settingsWindow: MooringSettingsWindow?
    private var initialLoad = true
    private var statusItem: NSStatusItem!
    private var statusShowsScreenSharing: Bool?
    private var updateTimer: Timer?
    private let statusMenu = NSMenu()
    private var lastMenuAction: String?
    private let table = NSTableView()
    /// Connections saved by the CLI store: Linux desktops through SSH, and
    /// addresses left from Apple Screen Sharing.
    private var connections: [SavedMac] = []
    private var rows: [ConnectionRow] = []
    private var busy = false
    private var addController: AddMacController?
    private let countLabel = label("0", size: 11, color: .secondaryLabelColor)
    private let titleLabel = label("Your Macs,\nwithin reach.", size: 34, weight: .semibold)
    private let computerInfo = stack([], spacing: 6)
    private let computerInfoScroll = NSScrollView()
    private let addressLabel = label("Connect there. Work here.", size: 14, color: .secondaryLabelColor)
    private let connectionKind = label("Within reach", size: 11, weight: .semibold, color: MooringBrand.accent)
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
        if case .saved(let mac) = selectedRow { return mac }
        return nil
    }
    private var selectedPeer: NativePeer? {
        if case .mooring(let peer) = selectedRow { return peer }
        return nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = NSImage(named: "Mooring") ?? MooringBrand.image(size: 512)
        buildMenu()
        buildWindow()
        buildStatusItem()
        native.onChange = { [weak self] in
            self?.updateControls()
            self?.refreshSettings()
            // A session that just ended may free a waiting update to install.
            DispatchQueue.main.async { self?.updater.installIfIdle() }
        }
        native.onPeersChange = { [weak self] in self?.rebuildRows(); self?.refreshSettings() }
        tunnels.onEvent = { [weak self] mac, event in self?.tunnelEvent(mac, event) }
        tunnels.onExit = { [weak self] mac, status, message in self?.tunnelExited(mac, status, message) }
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

    func applicationWillTerminate(_ notification: Notification) {
        native.stop()
        // Release held keys on the remote desktops before the tunnels close.
        for viewer in vncViewers.values where viewer.view.sessionID != 0 { _ = ml_vnc_close(viewer.view.sessionID) }
        tunnels.stopAll()
    }

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
            button.image = MooringBrand.menuBarImage
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
        let idle = connections.isEmpty && native.peers.isEmpty ? "Ready to pair" : "Ready to connect"
        let status = NSMenuItem(title: MooringPrivacy.redact(native.status ?? idle), action: nil, keyEquivalent: "")
        status.isEnabled = false
        statusMenu.addItem(status)
        let statusDescription = MooringPrivacy.redact("Mooring — \(native.status ?? idle)")
        statusItem.button?.toolTip = statusDescription
        statusItem.button?.setAccessibilityLabel(statusDescription)
        if statusShowsScreenSharing != native.isSharingScreen {
            statusShowsScreenSharing = native.isSharingScreen
            statusItem.button?.image = MooringBrand.menuBarImage(isSharingScreen: native.isSharingScreen)
        }
        if let lastMenuAction {
            let recent = NSMenuItem(title: MooringPrivacy.redact(lastMenuAction), action: nil, keyEquivalent: "")
            recent.isEnabled = false
            statusMenu.addItem(recent)
        }
        statusMenu.addItem(.separator())
        let available = !busy && addController == nil && window?.attachedSheet == nil
        MooringStatusMenu.addRecentMacs(native.peers, connectedPeerID: native.connectedPeerID,
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
        // Linux desktops open in Mooring's own viewer, like paired Macs.
        let desktops = connections.filter(\.opensInMooring)
        if !desktops.isEmpty {
            let heading = NSMenuItem(title: "Linux Desktops", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            statusMenu.addItem(heading)
            for mac in desktops {
                let name = MooringPrivacy.name(mac.name, id: mac.id)
                let title = name.count > 50 ? String(name.prefix(49)) + "…" : name
                let item = NSMenuItem(title: title, action: #selector(connectFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mac.id
                item.toolTip = MooringPrivacy.redact("\(mac.name) — \(mac.endpoint)")
                item.isEnabled = available
                if let viewer = vncViewers[mac.id], !viewer.isClosed { item.state = .on }
                statusMenu.addItem(item)
            }
            statusMenu.addItem(.separator())
        }
        let openItem = NSMenuItem(title: "Your Macs…", action: #selector(showConnections), keyEquivalent: "o")
        openItem.target = self
        statusMenu.addItem(openItem)
        let addItem = NSMenuItem(title: "Add Linux Desktop…", action: #selector(addMac), keyEquivalent: "n")
        addItem.target = self
        addItem.isEnabled = available
        statusMenu.addItem(addItem)
        statusMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        settings.toolTip = "Sharing, viewing, paired Macs and updates."
        statusMenu.addItem(settings)
        // Version and updates sit together, just above Quit.
        statusMenu.addItem(.separator())
        let release = Bundle.main.object(forInfoDictionaryKey: "MooringReleaseVersion") as? String ?? "development"
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
              let row = rows.firstIndex(where: { $0.id == ConnectionRow.savedID(id) }),
              !busy, window.attachedSheet == nil else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        connect()
    }

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
        MooringAppearance.prepare(window)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 610)
        window.setFrameAutosaveName("MooringMainWindow")
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
        let brandIcon = NSImageView(image: MooringBrand.image(size: 36))
        brandIcon.translatesAutoresizingMaskIntoConstraints = false
        brandIcon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        brandIcon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let brand = stack([brandIcon, stack([label("mooring", size: 21, weight: .semibold),
                                           label(MooringBrand.tagline, size: 10, color: .secondaryLabelColor)], spacing: 2)],
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
        icon.image = MooringBrand.image(size: 64)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 64), icon.heightAnchor.constraint(equalToConstant: 64)])
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        addressLabel.maximumNumberOfLines = 1
        addressLabel.lineBreakMode = .byTruncatingMiddle
        statusTitle.maximumNumberOfLines = 1
        statusTitle.lineBreakMode = .byTruncatingTail
        computerInfoScroll.translatesAutoresizingMaskIntoConstraints = false
        computerInfoScroll.drawsBackground = false
        computerInfoScroll.hasVerticalScroller = true
        computerInfoScroll.autohidesScrollers = true
        computerInfoScroll.documentView = computerInfo
        let intro = stack([icon, connectionKind, titleLabel, addressLabel, computerInfoScroll], spacing: 10)
        intro.detachesHiddenViews = true
        NSLayoutConstraint.activate([
            computerInfoScroll.widthAnchor.constraint(equalTo: intro.widthAnchor),
            computerInfoScroll.heightAnchor.constraint(equalToConstant: 100),
            computerInfo.leadingAnchor.constraint(equalTo: computerInfoScroll.contentView.leadingAnchor),
            computerInfo.topAnchor.constraint(equalTo: computerInfoScroll.contentView.topAnchor),
            computerInfo.widthAnchor.constraint(equalTo: computerInfoScroll.widthAnchor)
        ])
        let statusBox = MooringSurface()
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
        MooringAppearance.primary(connectButton)
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connect)
        connectButton.setAccessibilityLabel("Connect to the selected Mac or Linux desktop")
        checkButton.bezelStyle = .rounded
        checkButton.controlSize = .large
        checkButton.target = self
        checkButton.action = #selector(checkConnection)
        checkButton.toolTip = "Check the SSH route, the VNC server and whether the desktop is locked, without signing in"
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
        cell.nameLabel.stringValue = MooringPrivacy.name(item.name, id: item.id)
        cell.hostLabel.stringValue = MooringPrivacy.isEnabled ? MooringPrivacy.demoHostname(id: item.id) : item.detail
        cell.symbol.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        cell.setAccessibilityLabel("\(cell.nameLabel.stringValue), \(cell.hostLabel.stringValue)")
        return cell
    }

    /// Mooring pairings first, then saved desktops. Keeps the
    /// selection when the same entry is still present.
    private func rebuildRows(select id: String? = nil) {
        let selection = id ?? selectedRow?.id
        rows = native.peers.map(ConnectionRow.mooring) + connections.map(ConnectionRow.saved)
        for row in rows {
            let addresses: [String]
            switch row { case .mooring(let peer): addresses = peer.addresses; case .saved(let mac): addresses = [mac.host, mac.endpoint] + (mac.ssh.map { [$0.target] } ?? []) }
            MooringPrivacy.register(name: row.name, id: row.id, addresses: addresses)
        }
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
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !busy && addController == nil }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private func updateSelection() {
        connectionKind.isHidden = selectedRow == nil
        if let peer = selectedPeer {
            connectionKind.stringValue = "Paired"
            connectionIcon.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: nil)
            connectionIcon.contentTintColor = MooringBrand.accent
            titleLabel.stringValue = MooringPrivacy.name(peer.name, id: peer.id)
            titleLabel.toolTip = peer.name
            addressLabel.stringValue = MooringPrivacy.isEnabled ? MooringPrivacy.demoHostname(id: peer.id) : "Paired · " + peer.address
            addressLabel.toolTip = MooringPrivacy.isEnabled ? "There’s no route like home." : peer.addresses.joined(separator: "\n")
            setStatus("Ready", "On \(peer.name), open Mooring → Share this Mac → Start sharing.")
        } else if let mac = selectedMac {
            connectionKind.stringValue = mac.opensInMooring ? "Linux desktop" : mac.isMac ? "Needs pairing" : "Needs SSH"
            connectionIcon.image = NSImage(systemSymbolName: mac.opensInMooring ? "display" : "exclamationmark.triangle", accessibilityDescription: nil)
            connectionIcon.contentTintColor = mac.opensInMooring ? MooringBrand.accent : .systemOrange
            titleLabel.stringValue = MooringPrivacy.name(mac.name, id: mac.id)
            titleLabel.toolTip = mac.name
            addressLabel.stringValue = MooringPrivacy.isEnabled ? MooringPrivacy.demoHostname(id: mac.id) : mac.endpoint
            addressLabel.toolTip = MooringPrivacy.isEnabled ? "There’s no route like home." : mac.endpoint
            if mac.opensInMooring {
                setStatus("Ready", "Opens in Mooring through SSH. You sign in with that computer’s account.")
            } else if mac.isMac {
                setStatus("Pair this Mac", "Mooring no longer uses Apple Screen Sharing. On \(mac.name), open Mooring → Share this Mac, then choose Pair a Mac here. You can remove this saved address.")
            } else {
                setStatus("Needs SSH", "Mooring’s viewer reaches VNC servers only through SSH. Remove this entry and add it again with an SSH target.")
            }
        } else {
            connectionKind.stringValue = "Within reach"
            connectionIcon.image = MooringBrand.image(size: 64)
            connectionIcon.contentTintColor = nil
            titleLabel.stringValue = "Your Macs,\nwithin reach."
            titleLabel.toolTip = nil
            addressLabel.stringValue = "Connect there. Work here."
            addressLabel.toolTip = nil
            setStatus("Pair once. Return anytime.", "On your other Mac, open Mooring → Share this Mac. Start sharing and copy its code.\n\nFor a Linux desktop, add it with its SSH target.")
        }
        computerInfo.arrangedSubviews.forEach { $0.removeFromSuperview() }
        computerInfoScroll.isHidden = selectedRow == nil
        if MooringPrivacy.isEnabled, let row = selectedRow {
            for text in MooringPrivacy.demoNetworkInfo(id: row.id) {
                let info = label(text, size: 12, color: .secondaryLabelColor)
                computerInfo.addArrangedSubview(info)
                info.widthAnchor.constraint(equalTo: computerInfo.widthAnchor).isActive = true
            }
        } else {
            if let peer = selectedPeer {
                for (index, address) in peer.addresses.enumerated() {
                    let info = label("\(index == 0 ? "Last connected" : "Alternate") · \(NativeNetworkInfo.describe(address))\n\(address)", size: 12, color: .secondaryLabelColor)
                    computerInfo.addArrangedSubview(info)
                    info.widthAnchor.constraint(equalTo: computerInfo.widthAnchor).isActive = true
                }
            } else if let mac = selectedMac {
                let route = mac.ssh.map { "Through SSH \($0.target)\nVNC \(mac.host):\(mac.port) on that host" }
                    ?? "\(NativeNetworkInfo.describe(mac.host)) · \(mac.host)\nTCP port \(mac.port)"
                computerInfo.addArrangedSubview(label(route, size: 12, color: .secondaryLabelColor))
            }
        }
        updateControls()
    }

    private func setStatus(_ title: String, _ detail: String, error: Bool = false, success: Bool = false) {
        statusTitle.stringValue = title
        statusTitle.toolTip = title
        statusDetail.string = MooringPrivacy.redact(detail)
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
        let available = !busy && addController == nil && window?.attachedSheet == nil
        connectButton.isEnabled = available
        connectButton.action = selectedRow == nil ? #selector(connectNative) : #selector(connect)
        connectButton.title = busy ? "Connecting…" : selectedRow == nil ? "Pair a Mac…" : (selectedPeer.map { $0.id == native.connectedPeerID } ?? false) ? "Return" : "Connect"
        connectButton.setAccessibilityLabel(selectedRow == nil ? "Pair a Mac using a Mooring code" : MooringPrivacy.redact("Connect to \(selectedRow?.name ?? "Mac")"))
        checkButton.isHidden = selectedPeer != nil
        checkButton.title = selectedRow == nil ? "Add Linux Desktop…" : "Check"
        checkButton.action = selectedRow == nil ? #selector(addMac) : #selector(checkConnection)
        checkButton.toolTip = selectedRow == nil ? "Add a Linux desktop that you reach with SSH." : "Check the SSH route, the VNC server and the desktop’s lock state without signing in."
        checkButton.isEnabled = available && (selectedRow == nil || selectedMac?.opensInMooring == true)
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
            return !busy && addController == nil && window.attachedSheet == nil
        }
        if menuItem.action == #selector(addMac) {
            return !busy && addController == nil && window.attachedSheet == nil
        }
        if [#selector(connect), #selector(removeMac)].contains(menuItem.action) {
            return !busy && selectedRow != nil && window.attachedSheet == nil
        }
        if menuItem.action == #selector(checkConnection) {
            return !busy && selectedMac != nil && window.attachedSheet == nil
        }
        return window?.attachedSheet == nil
    }

    /// `id` selects a saved connection by its store ID.
    private func reloadConnections(select id: String? = nil, onLoaded: (() -> Void)? = nil) {
        let selection = id.map(ConnectionRow.savedID) ?? selectedRow?.id
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
        guard !busy, addController == nil, window.attachedSheet == nil else { return }
        showConnections()
        let controller = AddMacController()
        addController = controller
        controller.onCancel = { [weak self] in self?.closeAddSheet() }
        controller.onSave = { [weak self, weak controller] name, host, port, ssh, _ in
            guard let self, let controller, !self.busy else { return }
            let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
            guard portText.isEmpty || (UInt16(portText).map { $0 > 0 } ?? false) else {
                controller.errorLabel.stringValue = "Enter a port between 1 and 65535. The default is 5900."
                return
            }
            self.setBusy(true)
            controller.setBusy(true)
            var arguments = ["add", "--name", name.trimmingCharacters(in: .whitespacesAndNewlines),
                             "--port", portText.isEmpty ? "5900" : portText, "--server", "vnc", "--ssh", ssh]
            let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
            if !address.isEmpty { arguments += ["--host", address] }
            self.cli.run(arguments) { [weak self, weak controller] result in
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
        guard !busy, window.attachedSheet == nil else { return }
        if let peer = selectedPeer { forgetPairing(peer); return }
        guard let mac = selectedMac else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(MooringPrivacy.name(mac.name, id: mac.id))?"
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
        alert.messageText = "Forget \(MooringPrivacy.name(peer.name, id: peer.id))?"
        alert.informativeText = "This removes the pairing and its secret from this Mac. To connect again, copy a new pairing code from \(MooringPrivacy.name(peer.name, id: peer.id))."
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
        guard !busy, window.attachedSheet == nil else { return }
        if let peer = selectedPeer {
            lastMenuAction = "Connecting to \(peer.name.prefix(40))…"
            setStatus("Connecting…", "Connecting to \(peer.name). If it does not open, make sure \(peer.name) is sharing.")
            native.connect(peerID: peer.id)
            refreshStatusMenu()
            return
        }
        guard let mac = selectedMac else { return }
        guard mac.opensInMooring else { explainNotConnectable(mac); return }
        connectThroughSSH(mac)
    }

    /// Saved addresses that Mooring can no longer open: offer the way forward.
    private func explainNotConnectable(_ mac: SavedMac) {
        let alert = NSAlert()
        let name = MooringPrivacy.name(mac.name, id: mac.id)
        if mac.isMac {
            alert.messageText = "Pair \(name) with Mooring"
            alert.informativeText = "This address was saved for Apple Screen Sharing, which Mooring no longer uses. On \(name), open Mooring → Share this Mac and copy its code, then choose Pair a Mac here. You can then remove this saved address."
            alert.addButton(withTitle: "Pair a Mac…")
        } else {
            alert.messageText = "\(name) needs SSH"
            alert.informativeText = "Mooring’s viewer reaches VNC servers only through SSH, which checks the host and encrypts the connection. Remove this entry and add it again with its SSH target."
            alert.addButton(withTitle: "Add Linux Desktop…")
        }
        alert.addButton(withTitle: "Remove…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.updateControls()
            switch response {
            case .alertFirstButtonReturn: if mac.isMac { self.connectNative() } else { self.addMac() }
            case .alertSecondButtonReturn: DispatchQueue.main.async { self.removeMac() }
            default: break
            }
        }
        updateControls()
    }

    private func connectThroughSSH(_ mac: SavedMac) {
        guard let target = mac.ssh?.target else { return }
        if tunnels.isRunning(mac.id) {
            setStatus("Already connected through SSH", "\(mac.name)’s SSH tunnel is open. Close its viewer window to end it.", success: true)
            return
        }
        if let viewer = vncViewers[mac.id], !viewer.isClosed {
            viewer.showWindow(nil)
            return
        }
        do {
            tunnelEnded.remove(mac.id)
            desktopStates[mac.id] = nil
            // Mooring's own viewer connects; the tunnel waits up to 10 minutes
            // for sign-in and lingers 5 minutes between tries.
            let extra = ["--no-viewer", "--wait-seconds", "600", "--idle-seconds", "300"] + virtualScreenArguments()
            try tunnels.open(mac, executable: cli.executableURL(), extraArguments: extra)
        } catch {
            setStatus("Couldn’t start SSH", error.localizedDescription, error: true)
            return
        }
        lastMenuAction = "Connecting to \(mac.name.prefix(40)) through SSH…"
        setStatus("Connecting through SSH…", "Checking \(target) with your SSH keys and agent. Mooring never asks for a password.")
        refreshStatusMenu()
    }

    private func tunnelEvent(_ mac: SavedMac, _ event: [String: Any]) {
        let errorMessage = (event["error"] as? [String: Any])?["message"] as? String
        switch event["event"] as? String {
        case "check_retry":
            setStatus("Retrying SSH…", errorMessage ?? "The SSH connection dropped during setup.")
        case "ready":
            guard let port = (event["local_port"] as? NSNumber)?.uint16Value else { break }
            vncPending[mac.id] = port
            setStatus("Reached \(mac.name) through SSH", "Checking whether its desktop is locked before signing in…")
            // Wait briefly for the desktop check, so the prompt can say whether
            // the screen is locked and suggest the desktop's user name.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.presentVNCSignIn(mac) }
        case "desktop":
            // Read-only lock and display state. Mooring never unlocks the
            // desktop or types a password; the person signs in in the viewer.
            guard let title = event["title"] as? String, let message = event["message"] as? String else { return }
            let lock = event["lock"] as? String
            desktopStates[mac.id] = (event["session_user"] as? String, title, message)
            vncViewers[mac.id]?.showDesktop(title)
            if vncPending[mac.id] != nil { presentVNCSignIn(mac); return }
            lastMenuAction = "\(mac.name.prefix(40)): \(title)"
            setStatus("\(mac.name): \(title)", message, success: lock == "unlocked")
        case "virtual_screen":
            let width = event["width"] as? Int ?? 0, height = event["height"] as? Int ?? 0
            switch event["state"] as? String {
            case "ready":
                lastMenuAction = "\(mac.name.prefix(40)): screen matched to this Mac"
                if vncPending[mac.id] == nil {
                    setStatus("\(mac.name): screen matched", "Showing \(mac.name) on a \(width)×\(height) virtual screen sized to this Mac. Its own screen comes back when you disconnect.", success: true)
                }
            case "failed":
                setStatus("Showing \(mac.name)’s own screen", errorMessage ?? "Mooring couldn’t add a virtual screen there.")
            case "restore_unconfirmed":
                setStatus("Check \(mac.name)’s screen", "Mooring couldn’t confirm that \(mac.name)’s own screen was restored. It restores itself within about 20 seconds once the connection is gone.", error: true)
            default:
                return
            }
        case "failed":
            tunnelEnded.insert(mac.id)
            vncPending[mac.id] = nil
            vncViewers[mac.id]?.end("The SSH tunnel closed.")
            lastMenuAction = "SSH connection failed"
            setStatus("Couldn’t connect through SSH", errorMessage ?? "The SSH tunnel closed.", error: true)
            showConnections()
        case "closed":
            tunnelEnded.insert(mac.id)
            vncPending[mac.id] = nil
            if let viewer = vncViewers[mac.id], !viewer.isClosed, viewer.view.sessionID != 0 { viewer.end("The SSH tunnel closed.") }
            lastMenuAction = "SSH tunnel closed"
            let detail = event["reason"] as? String == "no_viewer"
                ? "No sign-in started in time, so the tunnel closed."
                : "The SSH tunnel to \(mac.name) has closed."
            setStatus("SSH tunnel closed", detail)
        default: return
        }
        refreshStatusMenu()
    }

    /// With Match this screen on, the Linux desktop shows on a virtual screen
    /// the size of this Mac's full-screen area (below the camera housing), so
    /// the viewer fills the screen. Rust checks the size.
    private func virtualScreenArguments() -> [String] {
        guard native.matchesScreen, let screen = NSScreen.main else { return [] }
        let scale = screen.backingScaleFactor
        guard scale == 1 || scale == 2 else { return [] }
        let width = Int((screen.frame.width * scale).rounded()) & ~1
        let height = Int(((screen.frame.height - screen.safeAreaInsets.top) * scale).rounded()) & ~1
        return ["--screen", "\(width)x\(height)@\(Int(scale))"]
    }

    /// Ask for the VNC server's sign-in, once the tunnel is ready. Rust decides
    /// whether another attempt is allowed; the password goes straight to Rust,
    /// which wipes the buffer before returning.
    private func presentVNCSignIn(_ mac: SavedMac) {
        guard let port = vncPending.removeValue(forKey: mac.id), tunnels.isRunning(mac.id) else { return }
        var wait: UInt64 = 0, remaining: UInt32 = 0
        let allowed = mac.id.withCString { ml_vnc_sign_in_check($0, &wait, &remaining) }
        if allowed == Int32(ML_SESSION_RATE_LIMITED) {
            let minutes = max(1, Int((wait + 59_999) / 60_000))
            tunnels.stop(mac.id)
            setStatus("Waiting before another sign-in", "Two sign-ins to \(mac.name) failed in the last 10 minutes, so Mooring waits about \(minutes) more minute\(minutes == 1 ? "" : "s") before another try. You can also sign in at the computer.", error: true)
            refreshStatusMenu()
            return
        }
        let desktop = desktopStates[mac.id]
        let sshUser = mac.ssh?.target.split(separator: "@", maxSplits: 1).count == 2 ? String(mac.ssh!.target.split(separator: "@")[0]) : nil
        var detail = "\(mac.name)’s VNC server asks for an account on that computer. Mooring sends it once, encrypted (RSA-AES) inside SSH, and doesn’t save it."
        if remaining == 1 { detail += "\n\nAfter one more failed sign-in, Mooring waits 10 minutes before another try." }
        if let desktop { detail += "\n\n\(desktop.title): \(desktop.message)" }
        setStatus("Sign in to \(mac.name)", "Waiting for the account name and password.")
        VNCSignIn.prompt(name: mac.name, username: sshUser ?? desktop?.user ?? "", detail: detail) { [weak self] answer in
            guard let self else { return }
            guard let answer, self.tunnels.isRunning(mac.id) else {
                self.tunnels.stop(mac.id)
                self.setStatus("Sign-in cancelled", "The SSH tunnel to \(mac.name) has been closed.")
                self.refreshStatusMenu()
                return
            }
            var password = answer.password
            var session: UInt64 = 0
            let status = mac.id.withCString { key in
                answer.username.withCString { user in
                    ml_vnc_open(key, port, user, &password, password.count, &session)
                }
            }
            guard status == 0, session != 0 else {
                self.tunnels.stop(mac.id)
                self.setStatus("Couldn’t start the viewer", String(cString: ml_session_error_string(status)), error: true)
                return
            }
            self.openVNCViewer(mac, session: session, port: port)
        }
    }

    private func openVNCViewer(_ mac: SavedMac, session: UInt64, port: UInt16) {
        if let old = vncViewers[mac.id] { old.onClose = nil; old.close() }
        let viewer = VNCViewerWindow(name: mac.name, connectionID: mac.id, sessionID: session)
        if let desktop = desktopStates[mac.id] { viewer.showDesktop(desktop.title) }
        viewer.onClose = { [weak self] in
            self?.vncViewers[mac.id] = nil
            self?.tunnels.stop(mac.id)
        }
        viewer.onSignInRejected = { [weak self, weak viewer] message in
            guard let self else { return }
            viewer?.onClose = nil
            viewer?.close()
            self.vncViewers[mac.id] = nil
            self.setStatus("Sign-in not accepted", message, error: true)
            guard self.tunnels.isRunning(mac.id) else { return }
            self.vncPending[mac.id] = port
            self.presentVNCSignIn(mac)
        }
        viewer.onEnded = { [weak self] message in
            self?.setStatus("\(mac.name): session ended", message ?? "The VNC session has ended.")
        }
        viewer.onReconnect = { [weak self] in
            guard let self else { return }
            if self.tunnels.isRunning(mac.id) {
                self.vncPending[mac.id] = port
                self.presentVNCSignIn(mac)
            } else {
                self.vncViewers[mac.id]?.onClose = nil
                self.vncViewers[mac.id]?.close()
                self.vncViewers[mac.id] = nil
                self.connectThroughSSH(mac)
            }
        }
        vncViewers[mac.id] = viewer
        lastMenuAction = "Viewing \(mac.name.prefix(40))"
        setStatus("Connecting to \(mac.name)…", "Signing in through SSH. Closing the viewer closes the tunnel.", success: true)
        viewer.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshStatusMenu()
    }

    private func tunnelExited(_ mac: SavedMac, _ status: Int32, _ message: String) {
        guard !tunnelEnded.contains(mac.id) else { return }
        // Exited without a final event, for example the CLI could not start.
        lastMenuAction = "SSH tunnel stopped"
        setStatus("SSH tunnel stopped", message.isEmpty ? "The SSH tunnel process exited (\(status))." : message, error: status != 0)
        refreshStatusMenu()
    }

    @objc private func checkConnection() {
        guard !busy, window.attachedSheet == nil, let mac = selectedMac else { return }
        setBusy(true)
        setStatus("Checking \(mac.name)…", "Testing SSH, the VNC server and the desktop. This does not sign in.")
        cli.run(["inspect", mac.id], timeout: mac.ssh == nil ? 20 : 30) { [weak self] result in
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
                    if let version = inspection.rfb_version { lines.append("VNC server: RFB \(version.trimmingCharacters(in: .whitespacesAndNewlines)).") }
                    if let note = inspection.note, !note.isEmpty { lines.append(note) }
                    if let desktop = inspection.desktop {
                        lines.append("Desktop: \(desktop.title). \(desktop.message)")
                        lines.append(contentsOf: desktop.notes ?? [])
                    } else if let failure = inspection.desktop_error {
                        lines.append("Mooring couldn’t read whether the desktop is locked: \(failure.message)")
                    }
                    self.setStatus("Connection check complete", lines.isEmpty ? "The host check completed. Connect to sign in." : lines.joined(separator: "\n"), success: true)
                } catch {
                    self.setStatus("Unexpected check response", "The Mooring command-line tool returned data this app could not read. \(error.localizedDescription)", error: true)
                }
            }
        }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let controller = MooringSettingsWindow()
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
            // Permissions and login approval change in System Settings.
            controller.onAppear = { [weak self] in self?.refreshSettings() }
            settingsWindow = controller
            controller.window?.center()
        }
        refreshSettings()
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshSettings() {
        guard let settingsWindow else { return }
        var state = MooringSettingsState()
        state.sharesAutomatically = native.sharesAutomatically
        state.sharesClipboard = native.sharesClipboard
        state.keyboardAndMouseAllowed = native.keyboardAndMouseAllowed
        let approved = native.approvedDevices()
        state.devices = approved?.devices
        state.legacy = approved?.legacy ?? NativeLegacyState()
        state.connectedDeviceID = native.connectedDeviceID
        state.matchesScreen = native.matchesScreen
        state.extendsBesideCamera = native.extendsBesideCamera
        state.playsSound = native.playsSound
        state.lowersDisplayLatency = native.lowersDisplayLatency
        state.showsDiagnosticBar = native.showsDiagnosticBar
        state.hidesComputerInformation = MooringPrivacy.isEnabled
        state.localNetwork = NativeNetworkInfo.local()
        let login = SMAppService.mainApp.status
        state.launchesAtLogin = login == .enabled || login == .requiresApproval
        state.loginNeedsApproval = login == .requiresApproval
        state.peers = native.peers
        state.connectedPeerID = native.connectedPeerID
        let local = NativeVersion.local
        state.version = "\(local.release == 0 ? (Bundle.main.object(forInfoDictionaryKey: "MooringReleaseVersion") as? String ?? "development") : local.name) (build \(local.build))"
        if let ready = updater.readyVersion { state.updates = .ready(updater.readyNativeVersion?.name ?? ready) }
        else { state.updates = updater.isAvailable ? .available : .unavailable }
        settingsWindow.show(state)
    }

    private func changeSetting(_ setting: MooringSetting, _ on: Bool) {
        switch setting {
        case .sharesAutomatically: native.setSharingAutomatically(on)
        case .sharesClipboard: native.sharesClipboard = on
        case .matchesScreen: native.matchesScreen = on
        case .extendsBesideCamera: native.extendsBesideCamera = on
        case .playsSound: native.playsSound = on
        case .lowersDisplayLatency: native.lowersDisplayLatency = on
        case .showsDiagnosticBar: native.showsDiagnosticBar = on
        case .hidesComputerInformation:
            MooringPrivacy.isEnabled = on
            native.refreshPrivacy()
            rebuildRows()
            statusDetail.string = MooringPrivacy.redact(statusDetail.string)
            if let addController { addController.close(); self.addController = nil }
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
        let alert = NSAlert(); alert.messageText = "Mooring Settings"; alert.informativeText = MooringPrivacy.redact(message)
        if let window = settingsWindow?.window, window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @objc private func showConnectionHelp() {
        guard window.attachedSheet == nil else { return }
        showConnections()
        let alert = NSAlert()
        alert.messageText = "Connecting to a Mac"
        alert.informativeText = "Pair: on your other Mac, open Mooring → Share this Mac. Start sharing, copy a code, then paste it into Pair a Mac here.\n\nLinux: run a VNC server such as wayvnc, then add the desktop with its SSH target. You sign in to it in Mooring each time; the password is never saved.\n\nMooring stays in the menu bar when you close this window."
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window) { [weak self] _ in self?.updateControls() }
        updateControls()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Mooring",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "MooringReleaseVersion") as? String ?? "Development",
            .applicationIcon: MooringBrand.image(size: 128),
            .credits: NSAttributedString(string: "Your Macs, within reach.")
        ])
    }
}

@main
private enum MooringMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
