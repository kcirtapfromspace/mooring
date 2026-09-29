import AppKit
import Foundation
import Darwin

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
            throw CLIError(message: "The MacLink command-line tool is missing. Rebuild the app with scripts/build-app.sh.")
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
            throw CLIError(message: message.isEmpty ? "The MacLink command-line tool exited unexpectedly (\(process.terminationStatus))." : message)
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

private final class MacCell: NSTableCellView {
    let nameLabel = label("", size: 13, weight: .medium)
    let hostLabel = label("", size: 11, color: .secondaryLabelColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let symbol = NSImageView(image: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)!)
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
    let saveButton = NSButton(title: "Add Mac", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var onSave: ((String, String, String) -> Void)?
    var onCancel: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Add a Mac"
        let title = label("Add a Mac", size: 22, weight: .semibold)
        let subtitle = label("Save an address so your next connection is one click away.", color: .secondaryLabelColor)
        for field in [nameField, hostField, portField] {
            field.delegate = self
            field.controlSize = .large
        }
        nameField.placeholderString = "Home Studio"
        hostField.placeholderString = "Mac-Studio.local or 192.168.1.20"
        nameField.setAccessibilityLabel("Mac name")
        hostField.setAccessibilityLabel("Hostname or IP address")
        portField.setAccessibilityLabel("Screen Sharing port")
        errorLabel.maximumNumberOfLines = 3
        errorLabel.lineBreakMode = .byTruncatingTail
        let form = NSGridView(views: [
            [label("Name"), nameField],
            [label("Address"), hostField],
            [label("Port"), portField]
        ])
        form.translatesAutoresizingMaskIntoConstraints = false
        form.rowSpacing = 12
        form.columnSpacing = 16
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill
        for row in 0..<3 { form.row(at: row).yPlacement = .center }
        saveButton.bezelStyle = .rounded
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
        let content = stack([title, subtitle, form, errorLabel, actions], spacing: 18)
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            content.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24),
            subtitle.widthAnchor.constraint(equalTo: content.widthAnchor),
            form.widthAnchor.constraint(equalTo: content.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            actions.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        window.initialFirstResponder = nameField
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func controlTextDidChange(_ obj: Notification) { validate() }
    private func validate() {
        saveButton.isEnabled = !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func setBusy(_ busy: Bool) {
        [nameField, hostField, portField].forEach { $0.isEnabled = !busy }
        cancelButton.isEnabled = !busy
        saveButton.isEnabled = !busy
        saveButton.title = busy ? "Saving…" : "Add Mac"
        if !busy { validate() }
    }
    @objc private func save() {
        guard saveButton.isEnabled else { return }
        errorLabel.stringValue = ""
        onSave?(nameField.stringValue, hostField.stringValue, portField.stringValue)
    }
    @objc private func cancel() { onCancel?() }
}

/// Automation owns policy and session actions; the shell only renders this state.
/// Coordinator callbacks and completions must be delivered on the main thread.
struct AutomationMenuState {
    var title: String = "Automation not configured"
    var detail: String = "Open Settings to configure automation for a saved Mac."
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
    private var automationState = AutomationMenuState()
    private var automationStarted = false
    private var initialLoad = true
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var lastMenuAction: String?
    private let table = NSTableView()
    private var connections: [SavedMac] = []
    private var busy = false
    private var addController: AddMacController?
    private let countLabel = label("0", size: 11, color: .secondaryLabelColor)
    private let titleLabel = label("Your Macs,\nwithin reach.", size: 30, weight: .semibold)
    private let addressLabel = label("Save your first Mac to get started.", size: 14, color: .secondaryLabelColor)
    private let statusTitle = label("Welcome to MacLink", size: 14, weight: .semibold)
    private let statusDetail = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 92))
    private let statusSymbol = NSImageView()
    private let spinner = NSProgressIndicator()
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let checkButton = NSButton(title: "Check Connection", target: nil, action: nil)
    private let addButton = NSButton(title: "Add Mac", target: nil, action: nil)
    private let removeButton = NSButton(title: "", target: nil, action: nil)

    private var selectedMac: SavedMac? {
        connections.indices.contains(table.selectedRow) ? connections[table.selectedRow] : nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        buildWindow()
        buildStatusItem()
        automation.onStateChange = { [weak self] state in
            guard let self else { return }
            self.automationState = state
            self.updateControls()
        }
        automationState = automation.state
        reloadConnections()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showConnections()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) { automation.stop() }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "MacLink")
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel("MacLink")
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
        let heading = NSMenuItem(title: "MacLink", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        statusMenu.addItem(heading)
        let status = NSMenuItem(title: automationState.title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        status.toolTip = automationState.detail
        statusMenu.addItem(status)
        statusItem.button?.toolTip = "MacLink — \(automationState.title)"
        if let lastMenuAction {
            let recent = NSMenuItem(title: lastMenuAction, action: nil, keyEquivalent: "")
            recent.isEnabled = false
            statusMenu.addItem(recent)
        }
        statusMenu.addItem(.separator())
        let available = !busy && !automationState.isBusy && addController == nil && window?.attachedSheet == nil
        let connectMenuItem = NSMenuItem(title: "Connect to Mac", action: nil, keyEquivalent: "")
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
        let openItem = NSMenuItem(title: "Open Connections…", action: #selector(showConnections), keyEquivalent: "o")
        openItem.target = self
        statusMenu.addItem(openItem)
        let addItem = NSMenuItem(title: "Add Mac…", action: #selector(addMac), keyEquivalent: "n")
        addItem.target = self
        addItem.isEnabled = available
        statusMenu.addItem(addItem)
        statusMenu.addItem(.separator())
        let preference = NSMenuItem(title: "Mode Preference", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        choices.autoenablesItems = false
        for (title, value) in [("Auto", "auto"), ("Standard", "standard"), ("Prefer High Performance", "high_performance")] {
            let item = NSMenuItem(title: title, action: #selector(changePreference(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value
            item.state = automation.selectedPreference == value ? .on : .off
            item.isEnabled = automationState.isConfigured && !automationState.isBusy
            choices.addItem(item)
        }
        preference.submenu = choices
        statusMenu.addItem(preference)
        let pauseItem = NSMenuItem(title: automationState.isPaused ? "Resume Automation" : "Pause Automation",
                                   action: #selector(toggleAutomation), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.isEnabled = automationState.isConfigured
        statusMenu.addItem(pauseItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        settings.isEnabled = available
        statusMenu.addItem(settings)
        statusMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MacLink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        statusMenu.addItem(quit)
    }

    @objc private func showConnections() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func connectFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let row = connections.firstIndex(where: { $0.id == id }),
              !busy, !automationState.isBusy, window.attachedSheet == nil else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        connect()
    }

    @objc private func toggleAutomation() {
        guard automationState.isConfigured else { return }
        automation.togglePause()
    }

    @objc private func changePreference(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        automation.setPreference(value)
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MacLink", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MacLink", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit MacLink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu(title: "File")
        file.submenu!.addItem(withTitle: "Open Connections…", action: #selector(showConnections), keyEquivalent: "o")
        file.submenu!.addItem(withTitle: "Add Mac…", action: #selector(addMac), keyEquivalent: "n")
        file.submenu!.addItem(withTitle: "Connect", action: #selector(connect), keyEquivalent: "\r")
        file.submenu!.addItem(withTitle: "Check Connection", action: #selector(checkConnection), keyEquivalent: "r")
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
        let help = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        help.submenu = NSMenu(title: "Help")
        help.submenu!.addItem(withTitle: "Connecting to a Mac", action: #selector(showConnectionHelp), keyEquivalent: "?")
        menu.addItem(help)
        for submenu in [appMenu, file.submenu!, help.submenu!] {
            for item in submenu.items where item.action == #selector(showAbout) || item.action == #selector(showSettings)
                || item.action == #selector(addMac) || item.action == #selector(connect)
                || item.action == #selector(checkConnection) || item.action == #selector(removeMac)
                || item.action == #selector(showConnections) || item.action == #selector(showConnectionHelp) {
                item.target = self
            }
        }
        NSApp.mainMenu = menu
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MacLink"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
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
            sidebar.widthAnchor.constraint(equalToConstant: 230),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            main.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let heading = stack([label("Saved Macs", size: 13, weight: .semibold), NSView(), countLabel], orientation: .horizontal)
        sidebar.addSubview(heading)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 58
        table.intercellSpacing = NSSize(width: 0, height: 3)
        table.backgroundColor = .clear
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.focusRingType = .none
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
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -20),
            heading.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: sidebarActions.topAnchor, constant: -16),
            sidebarActions.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            sidebarActions.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            sidebarActions.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18)
        ])
        let icon = NSImageView(image: NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 38, weight: .light)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 52), icon.heightAnchor.constraint(equalToConstant: 52)])
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        addressLabel.maximumNumberOfLines = 1
        addressLabel.lineBreakMode = .byTruncatingMiddle
        statusTitle.maximumNumberOfLines = 1
        statusTitle.lineBreakMode = .byTruncatingTail
        let intro = stack([icon, titleLabel, addressLabel], spacing: 12)
        let statusBox = NSView()
        statusBox.translatesAutoresizingMaskIntoConstraints = false
        statusBox.wantsLayer = true
        statusBox.layer?.cornerRadius = 12
        statusBox.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
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
        let detailHeight = detailScroll.heightAnchor.constraint(equalToConstant: 92)
        detailHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            detailHeight,
            detailScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            detailScroll.heightAnchor.constraint(lessThanOrEqualToConstant: 120)
        ])
        let statusCopy = stack([statusTitle, detailScroll], spacing: 6)
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
            statusTitle.widthAnchor.constraint(equalTo: statusCopy.widthAnchor),
            detailScroll.widthAnchor.constraint(equalTo: statusCopy.widthAnchor)
        ])
        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .large
        connectButton.font = .systemFont(ofSize: 14, weight: .semibold)
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
        let content = stack([intro, statusBox, buttons], spacing: 26)
        main.addSubview(content)
        let hint = label("Opens Apple Screen Sharing.\nDisplay mode is managed by Apple.", size: 12, color: .secondaryLabelColor)
        let help = NSButton(image: NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Connection help and display mode")!, target: self, action: #selector(showConnectionHelp))
        help.isBordered = false
        help.toolTip = "Connection help and display mode"
        let footer = stack([hint, NSView(), help], orientation: .horizontal, spacing: 10)
        main.addSubview(footer)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 36),
            content.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -36),
            content.topAnchor.constraint(equalTo: main.topAnchor, constant: 34),
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

    func numberOfRows(in tableView: NSTableView) -> Int { connections.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = MacCell()
        cell.nameLabel.stringValue = connections[row].name
        cell.hostLabel.stringValue = connections[row].endpoint
        cell.setAccessibilityLabel("\(connections[row].name), \(connections[row].endpoint)")
        return cell
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !busy && !automationState.isBusy && addController == nil }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private func updateSelection() {
        if let mac = selectedMac {
            titleLabel.stringValue = mac.name
            titleLabel.toolTip = mac.name
            addressLabel.stringValue = mac.endpoint
            addressLabel.toolTip = mac.endpoint
            setStatus("Ready when you are", "Connect opens Apple Screen Sharing. You’ll sign in there using the remote Mac’s account.")
        } else {
            titleLabel.stringValue = "Your Macs,\nwithin reach."
            titleLabel.toolTip = nil
            addressLabel.stringValue = "Save your first Mac to get started."
            addressLabel.toolTip = nil
            setStatus("Welcome to MacLink", "Enable Screen Sharing on the Mac you want to use, then add its local address.")
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
        NSAccessibility.post(element: statusTitle, notification: .valueChanged)
    }

    private func setBusy(_ value: Bool) {
        busy = value
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        updateControls()
    }

    private func updateControls() {
        let available = !busy && !automationState.isBusy && addController == nil && window?.attachedSheet == nil
        connectButton.isEnabled = available && selectedMac != nil
        checkButton.isEnabled = available && selectedMac != nil
        removeButton.isEnabled = available && selectedMac != nil
        addButton.isEnabled = available
        refreshStatusMenu()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showConnections) { return true }
        if menuItem.action == #selector(addMac) || menuItem.action == #selector(showSettings) {
            return !busy && !automationState.isBusy && addController == nil && window.attachedSheet == nil
        }
        if [#selector(connect), #selector(checkConnection), #selector(removeMac)].contains(menuItem.action) {
            return !busy && !automationState.isBusy && selectedMac != nil && window.attachedSheet == nil
        }
        return window?.attachedSheet == nil
    }

    private func reloadConnections(select id: String? = nil) {
        let selection = id ?? selectedMac?.id
        setBusy(true)
        cli.run(["list"]) { [weak self] result in
            guard let self else { return }
            self.setBusy(false)
            switch result {
            case .failure(let error):
                self.setStatus("Couldn’t load saved Macs", error.message, error: true)
                self.lastMenuAction = "Couldn’t load saved Macs"
                self.showConnections()
                self.refreshStatusMenu()
            case .success(let data):
                do {
                    self.connections = try JSONDecoder().decode([SavedMac].self, from: data)
                    self.countLabel.stringValue = String(self.connections.count)
                    self.table.reloadData()
                    if let row = self.connections.firstIndex(where: { $0.id == selection }) ?? (self.connections.isEmpty ? nil : 0) {
                        self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    } else {
                        self.table.deselectAll(nil)
                    }
                    self.updateSelection()
                    if self.automationStarted {
                        self.automation.updateConnections(self.connections)
                    } else {
                        self.automationStarted = true
                        self.automation.start(connections: self.connections)
                    }
                    if self.initialLoad && self.connections.isEmpty { self.showConnections() }
                    self.initialLoad = false
                } catch {
                    self.setStatus("Couldn’t read saved Macs", "The MacLink command-line tool returned an unexpected response. \(error.localizedDescription)", error: true)
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
                        self.reloadConnections(select: saved.id)
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
        guard !busy, !automationState.isBusy, window.attachedSheet == nil, let mac = selectedMac else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(mac.name)?"
        alert.informativeText = "This removes its saved address from MacLink. You can add it again anytime."
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

    @objc private func connect() {
        guard !busy, !automationState.isBusy, window.attachedSheet == nil, let mac = selectedMac else { return }
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
                self.setStatus("Handed off to Screen Sharing", "Complete sign-in in Apple’s app. The MacLink menu shows automation and session status when configured. A launch alone does not confirm the requested display mode.", success: true)
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
                    self.setStatus("Unexpected check response", "The MacLink command-line tool returned data this app could not read. \(error.localizedDescription)", error: true)
                }
            }
        }
    }

    @objc private func showSettings() {
        guard !busy, !automationState.isBusy, window.attachedSheet == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        automation.showSettings(connections: connections, parentWindow: window.isVisible ? window : nil)
        updateControls()
    }

    @objc private func showConnectionHelp() {
        guard window.attachedSheet == nil else { return }
        showConnections()
        let alert = NSAlert()
        alert.messageText = "Connecting to a Mac"
        alert.informativeText = "MacLink lives in your menu bar. Use its display icon to connect, open this window, or manage automation in Settings. Closing this window leaves MacLink running.\n\nOn the remote Mac, enable Screen Sharing in System Settings → General → Sharing, and allow the account you use to connect. Enter that Mac’s hostname or IP address in MacLink.\n\nApple Screen Sharing provides the remote session. Display-mode options depend on Apple’s app and the selected connection profile. Use MacLink Settings to configure available automation.\n\nMacLink saves names and addresses locally. Passwords are handled by Apple Screen Sharing."
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window) { [weak self] _ in self?.updateControls() }
        updateControls()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "MacLink",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "MacLinkReleaseVersion") as? String ?? "Development",
            .credits: NSAttributedString(string: "A menu bar companion with a Rust core.\nRemote sessions are provided by Apple Screen Sharing.")
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
