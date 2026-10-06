import AppKit

// Public display metadata only; these fixtures never open a connection/store.
struct NativePeer { let id: String; let name: String }

private final class ConnectionTarget: NSObject {
    var selectedID: String?
    @objc func connect(_ sender: NSMenuItem) { selectedID = sender.representedObject as? String }
}

@main
private enum StatusMenuTests {
    static func main() {
        _ = NSApplication.shared
        let suite = "mooring-privacy-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        MooringPrivacy.defaults = defaults
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = ConnectionTarget()
        let action = #selector(ConnectionTarget.connect(_:))
        let peers = (1...32).map { NativePeer(id: "fixture-\($0)", name: "Mac \($0)") }
        func menu(_ peers: [NativePeer], enabled: Bool = true, connected: String? = nil) -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            MooringStatusMenu.addRecentMacs(peers, connectedPeerID: connected, to: menu,
                                           target: target, action: action, enabled: enabled)
            return menu
        }
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fputs("Status menu failed: \(message)\n", stderr); exit(1) }
        }
        let empty = menu([])
        require(empty.items.first?.isSectionHeader == true, "empty list retains its section")
        require(empty.items.last?.isEnabled == false, "empty state cannot connect")
        for count in [1, 3, 4, 32] {
            let list = menu(Array(peers.prefix(count)), connected: peers[count - 1].id)
            let quick = list.items.filter { $0.action == action }
            require(quick.count == min(count, 3), "only three quick connections")
            let drawer = list.items.last?.submenu
            require((drawer != nil) == (count > 3), "drawer exists only for overflow")
            let all = quick + (drawer?.items ?? [])
            require(all.compactMap { $0.representedObject as? String } == peers.prefix(count).map(\.id),
                    "each peer appears once, in Rust's recency order")
            require(all.filter { $0.state == .on }.count == 1 && all.last?.state == .on,
                    "connected Mac is marked even in the drawer")
            list.performActionForItem(at: 1)
            require(target.selectedID == peers[0].id, "quick connection routes the peer ID")
            if let drawer {
                drawer.performActionForItem(at: drawer.items.count - 1)
                require(target.selectedID == peers[count - 1].id, "drawer connection routes the peer ID")
            }
        }
        let disabled = menu(Array(peers.prefix(5)), enabled: false)
        require(disabled.items.filter { !$0.isSectionHeader }.allSatisfy { !$0.isEnabled },
                "busy state disables quick connections and drawer")
        require(disabled.items.last?.submenu?.items.allSatisfy { !$0.isEnabled } == true,
                "busy state also disables drawer contents")
        let longName = String(repeating: "Studio ", count: 20)
        let long = menu([NativePeer(id: "long", name: longName)]).items[1]
        require(long.title.count == 50 && long.title.hasSuffix("…"), "long name fits the menu")
        require(long.toolTip == "Connect to \(longName)", "full name remains accessible")
        let source = "Editing Suite · edit.demo.local · 192.168.31.8 · fe80::9%en0 · ::1"
        MooringPrivacy.register(name: "Editing Suite", id: "private-demo", addresses: ["edit.demo.local", "192.168.31.8", "fe80::9%en0"])
        let field = MooringPrivacyLabel(labelWithString: "")
        field.observePrivacy(); field.stringValue = source; field.toolTip = source
        let privateWindow = MooringPrivacyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        privateWindow.title = "Editing Suite — Mooring"
        MooringPrivacy.isEnabled = true
        require(!privateWindow.title.contains("Editing Suite"), "an already-open viewer/permission title is masked")
        require(!field.stringValue.contains("Editing Suite") && !field.stringValue.contains("192.168") && !field.stringValue.contains("demo.local") && !field.stringValue.contains("fe80") && !field.stringValue.contains("::1"), "open label masks names, IPv4, scoped IPv6 and loopback IPv6")
        require(field.toolTip == field.stringValue, "tooltip is masked too")
        let hostname = MooringPrivacy.demoHostname(id: "private-demo")
        require(hostname.hasSuffix(".no-route-home.invalid") && hostname == MooringPrivacy.demoHostname(id: "mooring:private-demo"), "fictional DNS names are stable across row IDs")
        require(field.stringValue.contains(hostname) && field.stringValue.contains("2001:db8::dead:beef"), "known and unexpected addresses become reserved demo endpoints")
        let demoInfo = MooringPrivacy.demoNetworkInfo(id: "private-demo").joined(separator: "\n")
        require(MooringPrivacy.redact(demoInfo) == demoInfo && demoInfo.contains("NXDOMAIN sweet NXDOMAIN") && demoInfo.contains("192.0.2.1"), "DNS jokes and documentation addresses survive presentation redaction")
        require(MooringPrivacy.redact("Connect to 10.23.45.67:5900 or mystery.local") == "Connect to 192.0.2.1 or no-route-home.invalid", "unexpected error endpoints use fictional addresses too")
        let masked = menu([NativePeer(id: "private-demo", name: "Editing Suite")]).items[1]
        require(!masked.title.contains("Editing") && masked.toolTip == "Connect to \(masked.title)", "menu and tooltip use the same anonymous name")
        require(masked.representedObject as? String == "private-demo", "privacy keeps routing intact")
        require(defaults.bool(forKey: "view.hideComputerInformation"), "privacy preference persists")
        MooringPrivacy.isEnabled = false
        require(privateWindow.title == "Editing Suite — Mooring", "the original window title restores when privacy is off")
        require(field.stringValue == source && field.toolTip == source, "toggling off restores the open label")
        let idle = MooringBrand.menuBarImage
        let sharing = MooringBrand.menuBarImage(isSharingScreen: true)
        require(idle.isTemplate && sharing.isTemplate, "icons adapt to macOS menu appearance")
        require(idle.size == NSSize(width: 18, height: 18) && sharing.size == NSSize(width: 24, height: 18),
                "active badge has room without shrinking the Mooring mark")
        require(sharing.accessibilityDescription == "Mooring — sharing this Mac", "badge has a text equivalent")
        print("Status menu passed: recent/overflow routing, order, connected state, busy state, demo endpoints, privacy restoration, long names and sharing icon.")
    }
}
