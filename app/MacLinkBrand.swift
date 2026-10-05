import AppKit

/// Mooring's Threshold geometry is shared by the app and menu-bar icons.
/// The internal name remains stable for existing build and update tooling.
enum MacLinkBrand {
    static let name = "Mooring"
    static let tagline = "Your Macs, within reach."
    static let marigold = NSColor(srgbRed: 1, green: 212 / 255, blue: 71 / 255, alpha: 1)
    static let coral = NSColor(srgbRed: 1, green: 82 / 255, blue: 119 / 255, alpha: 1)
    static let turquoise = NSColor(srgbRed: 28 / 255, green: 201 / 255, blue: 183 / 255, alpha: 1)
    static let graphite = NSColor(srgbRed: 36 / 255, green: 39 / 255, blue: 38 / 255, alpha: 1)
    static let accent = NSColor(name: "MooringAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? turquoise : NSColor(srgbRed: 0.02, green: 0.42, blue: 0.38, alpha: 1)
    }
    static let canvas = NSColor(name: "MooringCanvas") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? graphite : NSColor(srgbRed: 1, green: 0.97, blue: 0.97, alpha: 1)
    }

    private static func panels() -> [NSBezierPath] {
        let left = NSBezierPath()
        left.move(to: NSPoint(x: 24, y: 22))
        left.curve(to: NSPoint(x: 54, y: 36), controlPoint1: NSPoint(x: 36, y: 26), controlPoint2: NSPoint(x: 50, y: 32))
        left.curve(to: NSPoint(x: 58, y: 45), controlPoint1: NSPoint(x: 57, y: 38), controlPoint2: NSPoint(x: 58, y: 41))
        left.line(to: NSPoint(x: 58, y: 90))
        left.curve(to: NSPoint(x: 24, y: 114), controlPoint1: NSPoint(x: 58, y: 96), controlPoint2: NSPoint(x: 45, y: 107))
        left.close()
        let right = NSBezierPath()
        right.move(to: NSPoint(x: 70, y: 34))
        right.curve(to: NSPoint(x: 76, y: 31), controlPoint1: NSPoint(x: 70, y: 31), controlPoint2: NSPoint(x: 73, y: 30))
        right.line(to: NSPoint(x: 94, y: 37))
        right.curve(to: NSPoint(x: 108, y: 54), controlPoint1: NSPoint(x: 106, y: 41), controlPoint2: NSPoint(x: 108, y: 45))
        right.line(to: NSPoint(x: 108, y: 114))
        right.curve(to: NSPoint(x: 82, y: 98), controlPoint1: NSPoint(x: 96, y: 111), controlPoint2: NSPoint(x: 82, y: 105))
        right.line(to: NSPoint(x: 82, y: 58))
        right.curve(to: NSPoint(x: 76, y: 48), controlPoint1: NSPoint(x: 82, y: 54), controlPoint2: NSPoint(x: 80, y: 51))
        right.line(to: NSPoint(x: 72, y: 45))
        right.curve(to: NSPoint(x: 70, y: 40), controlPoint1: NSPoint(x: 70, y: 44), controlPoint2: NSPoint(x: 70, y: 42))
        right.close()
        return [left, right]
    }

    static func image(size: CGFloat, appIcon: Bool = true) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.scaleBy(x: rect.width / 128, y: rect.height / 128)
            if appIcon {
                graphite.setFill()
                NSBezierPath(roundedRect: NSRect(x: 5, y: 5, width: 118, height: 118), xRadius: 27, yRadius: 27).fill()
                context.translateBy(x: 16, y: 12)
                context.scaleBy(x: 0.75, y: 0.75)
            } else {
                // Fit the silhouette, without the tile, into the status item.
                context.translateBy(x: -26, y: -26)
                context.scaleBy(x: 1.36, y: 1.36)
            }
            for (index, panel) in panels().enumerated() {
                (appIcon ? (index == 0 ? marigold : coral) : .black).setFill()
                panel.fill()
            }
            return true
        }
    }

    static var menuBarImage: NSImage {
        let image = image(size: 18, appIcon: false)
        image.isTemplate = true
        image.accessibilityDescription = name
        return image
    }
}
