import ApplicationServices

/// Accessibility lets Mooring send ⌘-Tab and other system shortcuts to a
/// paired Mac while viewing it. Mooring only asks; the person decides in
/// System Settings → Privacy & Security → Accessibility.
enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
