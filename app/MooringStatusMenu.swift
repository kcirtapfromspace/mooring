import AppKit

/// Presents Rust's most recently connected peer list without changing its order.
enum MooringStatusMenu {
    static func addRecentMacs(_ peers: [NativePeer], connectedPeerID: String?, to menu: NSMenu,
                              target: AnyObject, action: Selector, enabled: Bool) {
        menu.addItem(.sectionHeader(title: "Recent Macs"))
        guard !peers.isEmpty else {
            let empty = NSMenuItem(title: "No recent Macs", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        func item(for peer: NativePeer) -> NSMenuItem {
            let title = peer.name.count > 50 ? String(peer.name.prefix(49)) + "…" : peer.name
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = peer.id
            item.isEnabled = enabled
            item.state = peer.id == connectedPeerID ? .on : .off
            item.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
            item.toolTip = peer.id == connectedPeerID ? "Return to \(peer.name)" : "Connect to \(peer.name)"
            return item
        }

        for peer in peers.prefix(3) { menu.addItem(item(for: peer)) }
        let earlier = peers.dropFirst(3)
        if !earlier.isEmpty {
            let more = NSMenuItem(title: "More Macs", action: nil, keyEquivalent: "")
            let drawer = NSMenu(title: "More Macs")
            drawer.autoenablesItems = false
            for peer in earlier { drawer.addItem(item(for: peer)) }
            more.submenu = drawer
            more.isEnabled = enabled
            more.toolTip = "\(earlier.count) earlier \(earlier.count == 1 ? "connection" : "connections")"
            menu.addItem(more)
        }
    }
}
