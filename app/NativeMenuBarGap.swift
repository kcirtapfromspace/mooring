import AppKit

/// Sharing Mac: keeps part of the menu bar clear while a viewer shows it
/// beside that viewer's camera housing, and measures the menu bar for it.
///
/// The clear part is one empty status item. Status items line up from the
/// right, so the item's right edge stays where it is put whatever its length;
/// the length then reaches left to the gap's left edge, and status items to
/// its left move out of the gap. To move icons already under the housing,
/// the item must sit just right of the gap. macOS places a new status item
/// by its "NSStatusItem Preferred Position" default, in the order of the
/// items' stored positions rather than at an exact distance, so placement
/// is a short search: create a trial item at a position, see where it lands,
/// remove it, and halve the range, at most six times (about three seconds).
/// One item at a time: each one moves its neighbors. App menus
/// still take precedence; when they reach the gap, macOS hides status items.
/// Checked once a second while a viewer that reads it is connected. Main thread.
final class NativeMenuBarGap {
    /// The shared display's menu bar height in points, whenever it changes.
    var onHeight: ((Int) -> Void)?
    private var item: NSStatusItem?
    private var gap: (x: Int, width: Int)?
    private var timer: Timer?
    private var reportedHeight: Int?
    /// Preferred positions, in points from the right, still to try; the one
    /// that landed closest to the gap's right edge so far.
    private var search: (low: CGFloat, high: CGFloat, steps: Int, best: CGFloat?)?
    private var trial: NSStatusItem?
    private var searchGeneration = 0
    private var placedAt: TimeInterval = -.infinity
    /// The placed item sits right of the gap, rather than left of icons
    /// that already reach past it.
    private var clearsGap = false
    /// Seconds in a row the item's right edge has been inside the gap.
    private var shortSeconds = 0
    private static let name = "MooringCameraGap"
    private static let maxSteps = 6
    /// Status items to the item's right can grow, as a network meter does,
    /// and push icons back under the gap. Place again only when that lasts
    /// five seconds, at most every 30 seconds.
    private static let replaceAfter = 5
    private static let replaceSpacing: TimeInterval = 30

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
        guard next?.x != gap?.x || next?.width != gap?.width else { return }
        if let next { NativeLog.session.notice("keeping \(next.width) points of the menu bar clear for the viewer's camera") }
        else { NativeLog.session.notice("menu bar gap removed") }
        gap = next
        removeItems()
        if next != nil { place() }
    }
    /// The shared display changed: report its menu bar again, and place the
    /// gap on the new menu bar.
    func displayChanged() {
        reportedHeight = nil
        refresh()
        if gap != nil { removeItems(); place() }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        gap = nil; reportedHeight = nil; onHeight = nil
        removeItems()
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
        guard let gap, search == nil else { return }
        guard height > 0 else { removeItems(); return }
        let mayPlace = ProcessInfo.processInfo.systemUptime - placedAt >= Self.replaceSpacing
        guard let item, let frame = item.button?.window?.frame else {
            if mayPlace { removeItems(); place() }
            return
        }
        let right = frame.maxX - screen.frame.minX
        shortSeconds = clearsGap && right < CGFloat(gap.x + gap.width) - 4 ? shortSeconds + 1 : 0
        if shortSeconds >= Self.replaceAfter && mayPlace { removeItems(); place(); return }
        fit(item, right: right, gap: gap)
    }

    /// Searches for the slot whose right edge is nearest the gap's right edge
    /// without falling short of it.
    private func place() {
        guard let gap, let screen = sharedScreen, timer != nil, search == nil else { return }
        let target = screen.frame.maxX - (screen.frame.minX + CGFloat(gap.x + gap.width))
        searchGeneration &+= 1
        search = (low: 0, high: max(0, target), steps: 0, best: nil)
        probe(generation: searchGeneration)
    }
    private func probe(generation: Int) {
        guard generation == searchGeneration, let current = search, let gap, let screen = sharedScreen else { return }
        if current.steps >= Self.maxSteps || current.high - current.low < 8 {
            finish(current.best, gap: gap, screen: screen); return
        }
        let position = (current.low + current.high) / 2
        let candidate = makeItem(position: position)
        trial = candidate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, generation == self.searchGeneration, var current = self.search else { return }
            let right = candidate.button?.window.map { $0.frame.maxX - screen.frame.minX } ?? 0
            NSStatusBar.system.removeStatusItem(candidate); self.trial = nil
            current.steps += 1
            // Right of the gap: remember it, and try further left.
            if right >= CGFloat(gap.x + gap.width) { current.best = position; current.low = position }
            else { current.high = position }
            self.search = current
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.probe(generation: generation) }
        }
    }
    private func finish(_ best: CGFloat?, gap: (x: Int, width: Int), screen: NSScreen) {
        search = nil; placedAt = ProcessInfo.processInfo.systemUptime
        clearsGap = best != nil; shortSeconds = 0
        // When even the rightmost slot is left of the gap's right edge, the
        // icons under the housing can't move; the leftmost slot still keeps
        // icons added later out of it. The length is fitted once a second.
        item = makeItem(position: best ?? screen.frame.width)
        NativeLog.session.notice("\(best == nil ? "status items already reach past the viewer's camera; menu bar gap starts left of them" : "menu bar gap placed beside the viewer's camera", privacy: .public)")
    }
    /// The length that reaches from the item's right edge to the gap's left edge.
    private func fit(_ item: NSStatusItem, right: CGFloat, gap: (x: Int, width: Int)) {
        let length = max(1, (right - CGFloat(gap.x)).rounded(.up))
        if abs(item.length - length) >= 1 { item.length = length }
    }
    private func makeItem(position: CGFloat) -> NSStatusItem {
        UserDefaults.standard.set(Double(position), forKey: "NSStatusItem Preferred Position \(Self.name)")
        let item = NSStatusBar.system.statusItem(withLength: 1)
        item.autosaveName = Self.name
        item.behavior = []
        item.button?.isEnabled = false
        item.button?.setAccessibilityElement(false)
        return item
    }
    private func removeItems() {
        searchGeneration &+= 1
        if let trial { NSStatusBar.system.removeStatusItem(trial) }
        trial = nil; search = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }
}
