import AppKit

/// Sharing Mac: keeps part of the menu bar clear while a viewer shows it
/// beside that viewer's camera housing, and measures the menu bar for it.
/// The clear part is one empty status item. Status items line up from the
/// right, so this item's right edge is where the others end whatever its
/// length; the length reaches from there to the gap's left edge, and app
/// menus and other status items stay out of the gap as they do beside a real
/// notch. Status items that already extend past the gap stay where they are.
/// Checked once a second while a viewer that reads it is connected. Main thread.
final class NativeMenuBarGap {
    /// The shared display's menu bar height in points, whenever it changes.
    var onHeight: ((Int) -> Void)?
    private var item: NSStatusItem?
    private var gap: (x: Int, width: Int)?
    private var timer: Timer?
    private var reportedHeight: Int?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }
    /// Keeps `width` points clear from `x` points right of the shared
    /// display's left edge; a zero width clears nothing.
    func request(x: Int, width: Int) {
        let next = width > 0 ? (x: x, width: width) : nil
        if next?.x != gap?.x || next?.width != gap?.width {
            if let next { NativeLog.session.notice("keeping \(next.width) points of the menu bar clear for the viewer's camera") }
            else { NativeLog.session.notice("menu bar gap removed") }
        }
        gap = next
        refresh()
    }
    /// The shared display changed: report its menu bar again.
    func displayChanged() {
        reportedHeight = nil
        refresh()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        gap = nil; reportedHeight = nil; onHeight = nil
        removeItem()
    }

    /// The display with the menu bar, which is the one shared.
    private var sharedScreen: NSScreen? {
        let main = CGMainDisplayID()
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == main
        } ?? NSScreen.screens.first
    }

    private func refresh() {
        guard timer != nil, let screen = sharedScreen else { return }
        // Zero when the menu bar hides automatically.
        let height = Int(min(100, max(0, (screen.frame.maxY - screen.visibleFrame.maxY).rounded())))
        if height != reportedHeight { reportedHeight = height; onHeight?(height) }
        guard let gap, height > 0 else { removeItem(); return }
        let item = self.item ?? makeItem()
        guard let frame = item.button?.window?.frame, frame.maxX > screen.frame.minX, frame.maxX <= screen.frame.maxX + 1 else { return }
        let length = max(1, (frame.maxX - screen.frame.minX - CGFloat(gap.x)).rounded(.up))
        if abs(item.length - length) >= 1 { item.length = length }
    }
    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: 1)
        item.autosaveName = "MooringCameraGap"
        item.behavior = []
        item.button?.isEnabled = false
        item.button?.setAccessibilityElement(false)
        self.item = item
        return item
    }
    private func removeItem() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }
}
