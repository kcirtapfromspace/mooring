import AppKit
import ApplicationServices
import Darwin

/// Only endpoint and exported mode leave this parser. Never log plist or URL
/// contents: a native connection document can contain account information.
struct AppleSessionDocument: Equatable {
    let host: String
    let port: UInt16
    let mode: String?
    static let maximumBytes = 65_536

    static func canonicalHost(_ input: String) -> String? {
        guard !input.isEmpty, input.utf8.count <= 254,
              input.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) ||
                  (97...122).contains(byte) || [45, 46, 58, 91, 93].contains(byte)
              }) else { return nil }
        var host = input
        if host.hasPrefix("[") || host.hasSuffix("]") {
            guard host.hasPrefix("["), host.hasSuffix("]") else { return nil }
            host = String(host.dropFirst().dropLast())
            guard host.contains(":") else { return nil }
        }
        // Darwin accepts leading zeroes in dotted IPv4; the Rust endpoint
        // validator does not. Apply that rule to IPv4 tails inside IPv6 too.
        if host.contains(":"), host.contains(".") {
            guard let suffix = host.split(separator: ":").last else { return nil }
            let octets = suffix.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ octet in
                !octet.isEmpty && octet.utf8.allSatisfy({ (48...57).contains($0) }) &&
                UInt8(octet) != nil && (octet.count == 1 || octet.first != "0")
            }) else { return nil }
        }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &ipv6, &text, socklen_t(text.count)) != nil else { return nil }
            return String(cString: text).lowercased()
        }
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &text, socklen_t(text.count)) != nil else { return nil }
            let normalized = String(cString: text)
            return normalized == host ? normalized : nil
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= 253,
              !host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.allSatisfy({ label in
            if label.utf8.allSatisfy({ (48...57).contains($0) }) { return true }
            guard label.lowercased().hasPrefix("0x") else { return false }
            let digits = label.dropFirst(2)
            return !digits.isEmpty && digits.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
        }) { return nil }
        let lettersAndDigits = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let allowed = lettersAndDigits.union(CharacterSet(charactersIn: "-"))
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63,
                  let first = label.unicodeScalars.first, let last = label.unicodeScalars.last,
                  lettersAndDigits.contains(first), lettersAndDigits.contains(last),
                  label.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        }
        return host.lowercased()
    }

    static func parse(_ data: Data) -> AppleSessionDocument? {
        guard data.count <= maximumBytes,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let raw = plist["URL"] as? String,
              let url = URLComponents(string: raw), url.scheme?.lowercased() == "vnc",
              url.fragment == nil, url.path.isEmpty || url.path == "/",
              let encodedHost = url.percentEncodedHost,
              let decodedHost = encodedHost.removingPercentEncoding,
              let host = canonicalHost(decodedHost),
              let serialized = url.string, let hostRange = url.rangeOfHost else { return nil }
        // URLComponents reports nil for overflowing numeric ports as well as
        // absent ports. Only the latter may use the VNC default.
        let explicitPort = hostRange.upperBound < serialized.endIndex && serialized[hostRange.upperBound] == ":"
        if explicitPort, url.port == nil { return nil }
        let port = url.port ?? 5900
        guard (1...65_535).contains(port) else { return nil }
        let items = url.queryItems ?? []
        let qualities = items.filter { $0.name == "quality" }
        let displays = items.filter { $0.name == "numVirtualDisplays" }
        var mode: String?
        if qualities.count == 1, displays.count == 1 {
            if qualities[0].value == "high", displays[0].value == "1" { mode = "high_performance" }
            if ["adaptive", "full"].contains(qualities[0].value ?? ""), displays[0].value == "0" { mode = "standard" }
        }
        return AppleSessionDocument(host: host, port: UInt16(port), mode: mode)
    }

    /// Open once without following a leaf symlink, validate that descriptor, then
    /// read at most limit+1 bytes. Replacing the path cannot swap our open file.
    static func read(document: String) -> AppleSessionDocument? {
        guard let file = URL(string: document), file.isFileURL,
              file.host == nil || file.host == "" || file.host?.lowercased() == "localhost",
              file.user == nil, file.password == nil, file.port == nil,
              file.query == nil, file.fragment == nil, !file.path.utf8.contains(0),
              file.pathExtension.lowercased() == "vncloc" else { return nil }
        let descriptor = file.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_size >= 0, info.st_size <= maximumBytes else { return nil }
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else { return nil }
        return parse(data)
    }
}

/// Call all instance methods/properties on the same dedicated serial queue.
/// Ownership is a guarded heuristic: a new unique standard window must export
/// the requested endpoint and mode. A simultaneous same-endpoint/same-mode user
/// launch remains indistinguishable; do not describe this as absolute proof.
final class AppleSession {
    enum Observation { case waiting, connected, closing, closed, appExited, unavailable, ambiguous }
    private var before: [AXUIElement] = []
    private var owned: AXUIElement?
    private var pid: pid_t?
    private var began: TimeInterval = 0
    private var expectedHost = ""
    private var expectedPort: UInt16 = 5900
    private var requestedMode = ""
    private var preparationValid = false
    private var closeRequested = false
    private var connectionEnded = false
    private var lastFullscreenAttempt: TimeInterval = 0
    private var fullscreenSatisfied = false
    private(set) var observedMode: String?
    private(set) var isFullscreen: Bool?
    private(set) var lastIssue: String?

    var hasWindow: Bool { owned != nil }
    static var isTrusted: Bool { AXIsProcessTrusted() }
    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func running() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSharing")
    }
    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    private func elements(_ element: AXUIElement, _ key: String, limit: Int) -> [AXUIElement]? {
        AXUIElementSetMessagingTimeout(element, 0.2)
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, key as CFString, &count) == .success,
              count >= 0, count <= limit else { return nil }
        if count == 0 { return [] }
        var value: CFArray?
        guard AXUIElementCopyAttributeValues(element, key as CFString, 0, count, &value) == .success,
              let result = value as? [AXUIElement], result.count == count else { return nil }
        return result
    }
    private func windows(_ process: pid_t) -> [AXUIElement]? {
        elements(AXUIElementCreateApplication(process), kAXWindowsAttribute, limit: 32)
    }
    func prepare(for mac: SavedMac, mode: String) {
        reset()
        began = now
        guard Self.isTrusted, let host = AppleSessionDocument.canonicalHost(mac.host), mac.port > 0,
              ["standard", "high_performance"].contains(mode) else {
            lastIssue = "Accessibility access or a valid target and mode is required."
            return
        }
        expectedHost = host; expectedPort = mac.port; requestedMode = mode
        let applications = running()
        guard applications.count <= 1 else { lastIssue = "Multiple Screen Sharing processes are running."; return }
        if let app = applications.first {
            guard let snapshot = windows(app.processIdentifier) else { lastIssue = "Could not identify existing Screen Sharing windows."; return }
            pid = app.processIdentifier; before = snapshot
        }
        preparationValid = true
    }
    func reset() {
        owned = nil; pid = nil; before = []; began = 0
        observedMode = nil; isFullscreen = nil; lastIssue = nil
        preparationValid = false; closeRequested = false; connectionEnded = false
        lastFullscreenAttempt = 0; fullscreenSatisfied = false; requestedMode = ""; expectedHost = ""
    }
    private func document(_ window: AXUIElement) -> AppleSessionDocument? {
        guard let path = attribute(window, kAXDocumentAttribute) as? String else { return nil }
        return AppleSessionDocument.read(document: path)
    }
    private func matches(_ document: AppleSessionDocument) -> Bool {
        document.host == expectedHost && document.port == expectedPort
    }
    private func noSheets(_ window: AXUIElement, deadline: TimeInterval) -> Bool {
        AXUIElementSetMessagingTimeout(window, 0.2)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, "AXSheets" as CFString, &value)
        if result == .success { return (value as? [AXUIElement])?.isEmpty == true }
        // AXSheets is optional on ordinary AppKit windows. Missing/unsupported
        // falls back to verified direct child roles; transport errors do not.
        guard result == .noValue || result == .attributeUnsupported,
              let children = elements(window, kAXChildrenAttribute, limit: 32) else { return false }
        for child in children {
            guard now < deadline, let role = attribute(child, kAXRoleAttribute) as? String else { return false }
            if role == kAXSheetRole || role == "AXDialog" { return false }
        }
        return true
    }
    private func fail(_ issue: String, as observation: Observation = .ambiguous) -> Observation {
        observedMode = nil; isFullscreen = nil; lastIssue = issue
        return observation
    }
    func observe(fullscreen: Bool, shouldAct: () -> Bool = { true }) -> Observation {
        guard Self.isTrusted else { return fail("Accessibility access is unavailable.", as: .unavailable) }
        guard preparationValid else { return fail(lastIssue ?? "Session tracking has not been prepared.") }
        if connectionEnded { return .closed }
        let deadline = now + 2
        let applications = running()
        guard applications.count <= 1 else { return fail("Multiple Screen Sharing processes are running.") }
        guard let app = applications.first else {
            if pid != nil { return fail("Screen Sharing exited.", as: .appExited) }
            return now - began > 90 ? fail("No verified session appeared before the deadline.") : .waiting
        }
        if let previous = pid, previous != app.processIdentifier {
            return fail("Screen Sharing restarted; its windows are no longer owned.", as: .appExited)
        }
        pid = app.processIdentifier
        guard let current = windows(app.processIdentifier) else {
            return fail("Could not read Screen Sharing windows.", as: .unavailable)
        }
        if let window = owned, !current.contains(where: { CFEqual($0, window) }) {
            owned = nil; connectionEnded = true; observedMode = nil; isFullscreen = nil
            return .closed
        }
        if closeRequested { return .closing }

        var matchesEndpoint: [(AXUIElement, AppleSessionDocument)] = []
        for window in current where !before.contains(where: { CFEqual($0, window) }) {
            guard now < deadline else { return fail("Screen Sharing inspection exceeded its time budget.", as: .unavailable) }
            guard attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                  let profile = document(window), matches(profile) else { continue }
            matchesEndpoint.append((window, profile))
        }
        guard matchesEndpoint.count <= 1 else { return fail("Multiple new windows match this target; automatic actions are paused.") }
        guard let candidate = matchesEndpoint.first else {
            if owned != nil { return fail("The tracked window no longer exports the expected target.") }
            return now - began > 90 ? fail("The session could not be identified from its connection document.") : .waiting
        }
        if let window = owned, !CFEqual(window, candidate.0) {
            return fail("The matching window changed; automatic actions are paused.")
        }
        observedMode = candidate.1.mode
        guard candidate.1.mode == requestedMode else {
            isFullscreen = nil; lastIssue = "The session document does not confirm the requested mode."
            return .ambiguous
        }
        guard now < deadline else { return fail("Screen Sharing inspection exceeded its time budget.", as: .unavailable) }
        guard noSheets(candidate.0, deadline: deadline) else {
            return now - began > 90 ? fail("Session authentication or sheet state could not be verified.") : .waiting
        }
        guard shouldAct() else { return .waiting }
        owned = candidate.0
        lastIssue = nil
        updateFullscreen(candidate.0, requested: fullscreen, shouldAct: shouldAct)
        return shouldAct() ? .connected : .waiting
    }
    private func updateFullscreen(_ window: AXUIElement, requested: Bool, shouldAct: () -> Bool) {
        isFullscreen = attribute(window, "AXFullScreen") as? Bool
        if requested, isFullscreen == true { fullscreenSatisfied = true }
        if requested, isFullscreen == nil { lastIssue = "This session does not expose a readable full-screen state." }
        // Once confirmed, respect the user's later exit from full screen.
        guard requested, !fullscreenSatisfied, isFullscreen == false, now - lastFullscreenAttempt >= 5 else { return }
        lastFullscreenAttempt = now
        var settable = DarwinBoolean(false)
        AXUIElementSetMessagingTimeout(window, 0.2)
        guard AXUIElementIsAttributeSettable(window, "AXFullScreen" as CFString, &settable) == .success,
              settable.boolValue else { lastIssue = "This session does not expose a writable full-screen state."; return }
        guard shouldAct() else { return }
        _ = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
        // An accepted action is not state confirmation; asynchronous transitions
        // will be reflected by a subsequent observation.
        isFullscreen = attribute(window, "AXFullScreen") as? Bool
        if isFullscreen == true { fullscreenSatisfied = true }
    }
    /// Initiates close only after a fresh ownership/mode/ambiguity check. A true
    /// result means close was requested; it does NOT mean reconnect is safe yet.
    func closeOwnedWindow(shouldAct: () -> Bool = { true }) -> Bool {
        guard shouldAct() else { return false }
        guard !closeRequested else { return true }
        guard case .connected = observe(fullscreen: false, shouldAct: shouldAct), let window = owned,
              let button = attribute(window, kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        let closeButton = unsafeBitCast(button, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(closeButton, 0.2)
        guard shouldAct() else { return false }
        let result = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        // CannotComplete can mean the action started a modal confirmation.
        // Preserve identity and poll; never send a duplicate close automatically.
        if result == .success || result == .cannotComplete { closeRequested = true; return true }
        lastIssue = "Screen Sharing did not accept the close request."
        return false
    }
    /// True only after observing the original window disappear or its process
    /// exit. AX read failures and process replacement are not closure evidence.
    func pollOwnedWindowClosed() -> Bool {
        if connectionEnded { return true }
        guard closeRequested else { return connectionEnded }
        guard Self.isTrusted, let process = pid, let window = owned else { return false }
        let applications = running()
        guard applications.count <= 1 else { return false }
        if applications.isEmpty {
            owned = nil; connectionEnded = true; observedMode = nil; isFullscreen = nil
            return true
        }
        guard applications[0].processIdentifier == process, let current = windows(process) else { return false }
        guard !current.contains(where: { CFEqual($0, window) }) else { return false }
        owned = nil; connectionEnded = true; observedMode = nil; isFullscreen = nil
        return true
    }
}
