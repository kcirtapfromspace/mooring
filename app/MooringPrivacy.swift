import AppKit

/// A presentation preference only. It never changes stored endpoints or keys.
enum MooringPrivacy {
    static let changed = Notification.Name("MooringPrivacyChanged")
    private static let preference = "view.hideComputerInformation"
    static var defaults: UserDefaults = {
        if let suite = ProcessInfo.processInfo.environment["MOORING_DEFAULTS_SUITE"] { return UserDefaults(suiteName: suite) ?? .standard }
        return .standard
    }()
    private static var aliases: [String: String] = [:]
    private static var replacements: [String: String] = [:]
    private static var replacementPattern: NSRegularExpression?
    // RFC 5737/3849 documentation addresses and RFC 2606's reserved DNS suffix.
    private static let demoIPv4 = "192.0.2.1"
    private static let demoIPv6 = "2001:db8::dead:beef"
    private static let addressPatterns: [(NSRegularExpression, String)] = [
        (#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b"#, demoIPv4),
        (#"(?i)\b(?:[a-z0-9-]+\.)+local\b"#, "no-route-home.invalid"),
        (#"(?i)(?<![a-z0-9])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:]+(?:%[a-z0-9]+)?"#, demoIPv6)
    ].compactMap { pattern, replacement in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (regex, replacement)
    }
    private static func remember(_ source: String, as replacement: String) {
        guard !source.isEmpty, replacements[source] != replacement else { return }
        replacements[source] = replacement
        replacementPattern = nil
    }
    static var isEnabled: Bool {
        get { defaults.bool(forKey: preference) }
        set {
            defaults.set(newValue, forKey: preference)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    private static func canonical(_ id: String) -> String {
        for prefix in ["mooring:", "screen-sharing:"] where id.hasPrefix(prefix) { return String(id.dropFirst(prefix.count)) }
        return id
    }
    private static func alias(for id: String) -> String {
        let id = canonical(id)
        if let alias = aliases[id] { return alias }
        let alias = "Mac \(aliases.count + 1)"
        aliases[id] = alias
        return alias
    }
    static func demoHostname(id: String) -> String {
        alias(for: id).lowercased().replacingOccurrences(of: " ", with: "-") + ".no-route-home.invalid"
    }
    static func demoNetworkInfo(id: String) -> [String] {
        ["DNS · NXDOMAIN sweet NXDOMAIN\n\(demoHostname(id: id))",
         "IPv4 · Gateway to nowhere\n\(demoIPv4)",
         "IPv6 · Dead beef, dead end\n\(demoIPv6)"]
    }
    static func register(name: String, id: String, addresses: [String] = []) {
        let id = canonical(id)
        remember(name, as: alias(for: id))
        for address in addresses { remember(address, as: demoHostname(id: id)) }
    }
    static func name(_ name: String, id: String) -> String {
        register(name: name, id: id)
        return isEnabled ? aliases[canonical(id)]! : name
    }
    static func redact(_ text: String) -> String {
        guard isEnabled else { return text }
        // One pass avoids masking aliases again when a real name resembles one.
        var result = text
        if replacementPattern == nil && !replacements.isEmpty {
            let sources = replacements.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
            replacementPattern = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:" + sources.joined(separator: "|") + ")(?![\\p{L}\\p{N}])", options: .caseInsensitive)
        }
        if let regex = replacementPattern {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let source = String(result[range])
                let key = replacements.keys.first { $0.caseInsensitiveCompare(source) == .orderedSame }
                if let key { result.replaceSubrange(range, with: replacements[key]!) }
            }
        }
        // Also cover addresses returned in network/OS errors that aren't saved.
        for (pattern, replacement) in addressPatterns {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        return result
    }
}

/// Keep the original in memory so toggling updates open windows immediately.
final class MooringPrivacyLabel: NSTextField {
    private var original = ""
    private var originalTip: String?
    private var observer: NSObjectProtocol?
    override var stringValue: String {
        get { super.stringValue }
        set { original = newValue; super.stringValue = MooringPrivacy.redact(newValue) }
    }
    override var toolTip: String? {
        get { super.toolTip }
        set { originalTip = newValue; super.toolTip = newValue.map(MooringPrivacy.redact) }
    }
    func observePrivacy() {
        observer = NotificationCenter.default.addObserver(forName: MooringPrivacy.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.stringValue = self.original
            self.toolTip = self.originalTip
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

/// Dynamic computer titles follow the same view preference as their labels.
final class MooringPrivacyWindow: NSWindow {
    private var originalTitle = ""
    private var observer: NSObjectProtocol?
    override var title: String {
        get { super.title }
        set { originalTitle = newValue; refreshPrivacy() }
    }
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        observer = NotificationCenter.default.addObserver(forName: MooringPrivacy.changed, object: nil, queue: .main) { [weak self] _ in self?.refreshPrivacy() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private func refreshPrivacy() {
        super.title = MooringPrivacy.redact(originalTitle)
        contentView?.setAccessibilityIdentifier("Mooring." + super.title)
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
