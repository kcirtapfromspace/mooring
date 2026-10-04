import AppKit

/// The same geometric connection mark is used in the app icon and menu bar.
/// Keep this file independent of the shell so the build can render the icon.
enum MacLinkBrand {
    static let tagline = "Your Macs, within reach."
    static let cobalt = NSColor(srgbRed: 33 / 255, green: 79 / 255, blue: 204 / 255, alpha: 1)
    static let accent = NSColor(name: "MacLinkCobalt") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 136 / 255, green: 170 / 255, blue: 1, alpha: 1)
            : cobalt
    }

    /// Two opposed paths and a central bridge: a connection in both directions.
    private static func connectionMark() -> NSBezierPath {
        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: 39, y: 73))
        mark.line(to: NSPoint(x: 20, y: 50))
        mark.line(to: NSPoint(x: 39, y: 27))
        mark.move(to: NSPoint(x: 61, y: 73))
        mark.line(to: NSPoint(x: 80, y: 50))
        mark.line(to: NSPoint(x: 61, y: 27))
        mark.move(to: NSPoint(x: 38, y: 50))
        mark.line(to: NSPoint(x: 62, y: 50))
        mark.lineWidth = 8
        mark.lineJoinStyle = .miter
        mark.lineCapStyle = .butt
        return mark
    }

    static func image(size: CGFloat, appIcon: Bool = true) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.scaleBy(x: rect.width / 100, y: rect.height / 100)
            let tile = NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: 88, height: 88), xRadius: 20, yRadius: 20)
            if appIcon {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.shadowBlurRadius = 3
                shadow.set()
                cobalt.setFill()
                tile.fill()
                NSShadow().set()
                NSColor.white.withAlphaComponent(0.14).setStroke()
                tile.lineWidth = 0.7
                tile.stroke()
            } else {
                // Fill the available menu-bar area with a legible silhouette.
                context.translateBy(x: -16.667, y: -16.667)
                context.scaleBy(x: 1.333, y: 1.333)
            }
            let ink: NSColor = appIcon ? .white : .black
            ink.setStroke()
            connectionMark().stroke()
            return true
        }
    }

    static var menuBarImage: NSImage {
        let image = image(size: 18, appIcon: false)
        image.isTemplate = true
        image.accessibilityDescription = "MacLink"
        return image
    }
}
