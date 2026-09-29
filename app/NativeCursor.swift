import AppKit

/// Sharing Mac: follows this Mac's pointer image through the public
/// NSCursor.currentSystem, ten times a second during a session, and reports
/// each change. Comparing raw pixels keeps an unchanged pointer nearly free.
final class NativeCursorWatcher {
    var onChange: ((NativeCursorImage) -> Void)?
    private var timer: Timer?
    private var lastPixels: Data?
    private var lastHotspot = NSPoint(x: -1, y: -1)

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        sample()
    }
    func stop() {
        timer?.invalidate(); timer = nil; lastPixels = nil
    }
    /// Sends the current pointer again, as to a viewer that just connected.
    func resend() { lastPixels = nil; sample() }

    private func sample() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image, size = image.size
        guard (1...256).contains(size.width), (1...256).contains(size.height),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width.rounded(.up)) * 2,
                                         pixelsHigh: Int(size.height.rounded(.up)) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep), let bytes = rep.bitmapData else { return }
        rep.size = NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: size)); NSGraphicsContext.restoreGraphicsState()
        let pixels = Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
        guard pixels != lastPixels || cursor.hotSpot != lastHotspot else { return }
        lastPixels = pixels; lastHotspot = cursor.hotSpot
        guard let png = rep.representation(using: .png, properties: [:]), png.count < 60_000 else { return }
        let width = Int(size.width.rounded(.up)), height = Int(size.height.rounded(.up))
        onChange?(NativeCursorImage(width: width, height: height,
                                    hotspotX: min(width - 1, max(0, Int(cursor.hotSpot.x))),
                                    hotspotY: min(height - 1, max(0, Int(cursor.hotSpot.y))), png: png))
    }
}

extension NativeCursorImage {
    /// The pointer as this Mac draws it, at its size in points.
    var cursor: NSCursor? {
        guard let image = NSImage(data: png) else { return nil }
        image.size = NSSize(width: width, height: height)
        return NSCursor(image: image, hotSpot: NSPoint(x: hotspotX, y: hotspotY))
    }
}
