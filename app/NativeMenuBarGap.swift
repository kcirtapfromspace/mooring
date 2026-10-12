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
/// is a search: create a trial item at a position, see where it lands, and
/// remove it. Trials start at the gap's own distance from the right edge.
/// While they land right of the gap they double, since stored positions can
/// be larger than distances, as for icons arranged on a fuller menu bar.
/// Then they halve the range down to a point. Some slots are reachable only
/// through a window of 10 to 20 points of position, so a coarser search can
/// skip the nearest one. One trial at a time: each one moves its neighbors.
/// Each is read once it stops sliding into place, about half a second, for
/// typically 10 to 13 trials. App menus still take precedence; when they
/// reach the gap, macOS hides status items. Checked once a second while a
/// viewer that reads it is connected. Main thread.
final class NativeMenuBarGap {
    /// The shared display's menu bar height in points, whenever it changes.
    var onHeight: ((Int) -> Void)?
    private var item: NSStatusItem?
    private var gap: (x: Int, width: Int)?
    private var timer: Timer?
    private var reportedHeight: Int?
    /// Preferred positions, in points from the right: the largest tried that
    /// landed right of the gap, and the smallest that didn't.
    private struct Search {
        let start: CGFloat
        var low: CGFloat?, high: CGFloat?, trials = 0
        /// The next position to try, or nil when the slot is found.
        var next: CGFloat? {
            if let high { let floor = low ?? 0; return high - floor >= 1 ? (floor + high) / 2 : nil }
            guard let low else { return start }
            return low < NativeMenuBarGap.positionLimit ? min(NativeMenuBarGap.positionLimit, low * 2) : nil
        }
    }
    private var search: Search?
    /// The last placement's position and trials, for the log.
    private var placement: (position: CGFloat?, trials: Int)?
    private var trial: NSStatusItem?
    private var searchGeneration = 0
    private var placedAt: TimeInterval = -.infinity
    /// The placed item sits right of the gap, rather than left of icons
    /// that already reach past it.
    private var clearsGap = false
    /// Room to spare between the gap's right edge and the item's, as placed;
    /// nil until measured.
    private var placedSpare: CGFloat?
    /// Seconds in a row the spare room has drifted from the placement.
    private var driftSeconds = 0
    private static let name = "MooringCameraGap"
    private static let maxTrials = 16
    /// The largest position tried; macOS puts an item there leftmost.
    fileprivate static let positionLimit: CGFloat = 16_384
    /// A slot this little short of the gap's right edge still clears the
    /// housing: the viewer's gap has a margin each side.
    private static let tolerance: CGFloat = 4
    /// Status items to the item's right grow and shrink, as a network meter
    /// does. Place again when they push icons into the gap for five seconds,
    /// or leave more than half an icon's room beyond the placement's for ten;
    /// at most every 30 seconds.
    private static let extraSpare: CGFloat = 24
    /// More room to spare than this usually means icons that share one
    /// stored position, a block nothing can be placed inside.
    private static let wideSpare: CGFloat = 64
    private static let replaceWhenShort = 5
    private static let replaceWhenSpare = 10
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
        let right = frame.maxX - screen.frame.minX, spare = right - CGFloat(gap.x + gap.width)
        if clearsGap {
            if placedSpare == nil {
                placedSpare = spare
                let position = placement?.position.map { "position \(Int($0.rounded()))" } ?? "leftmost"
                let points = Int(spare.rounded())
                NativeLog.session.notice("menu bar gap placed beside the viewer's camera, \(points) point\(points == 1 ? "" : "s", privacy: .public) to spare on its right (\(position, privacy: .public) after \(self.placement?.trials ?? 0) trials)")
                if spare > Self.wideSpare {
                    NativeLog.session.notice("the menu bar icons left of the gap may share one stored position, which keeps them together; ⌘-drag each of them once on this Mac so the gap can fit the viewer's camera")
                }
            }
            let short = spare < -Self.tolerance, roomy = spare > (placedSpare ?? spare) + Self.extraSpare
            driftSeconds = short || roomy ? driftSeconds + 1 : 0
            if driftSeconds >= (short ? Self.replaceWhenShort : Self.replaceWhenSpare) && mayPlace { removeItems(); place(); return }
        }
        fit(item, right: right, padding: frame.width - item.length, gap: gap)
    }

    /// Searches for the slot whose right edge is nearest the gap's right edge
    /// without falling short of it.
    private func place() {
        guard let gap, let screen = sharedScreen, timer != nil, search == nil else { return }
        let distance = screen.frame.maxX - (screen.frame.minX + CGFloat(gap.x + gap.width))
        searchGeneration &+= 1
        search = Search(start: max(1, distance.rounded()))
        probe(generation: searchGeneration)
    }
    private func probe(generation: Int) {
        guard generation == searchGeneration, let current = search else { return }
        guard current.trials < Self.maxTrials, let position = current.next else { finish(current); return }
        let candidate = makeItem(position: position)
        trial = candidate
        settled(candidate, generation: generation) { [weak self] right in
            guard let self, var current = self.search, let gap = self.gap else { return }
            NSStatusBar.system.removeStatusItem(candidate); self.trial = nil
            current.trials += 1
            // Right of the gap: remember it, and try further left.
            if right >= CGFloat(gap.x + gap.width) - Self.tolerance { current.low = position }
            else { current.high = position }
            self.search = current
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.probe(generation: generation) }
        }
    }
    /// The item's right edge once it stops moving: macOS slides a new status
    /// item into place, and an early reading is an item's width short. Read
    /// every 0.15 seconds until two agree, at most six times.
    private func settled(_ item: NSStatusItem, generation: Int, previous: CGFloat? = nil, reads: Int = 0,
                         then: @escaping (CGFloat) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, generation == self.searchGeneration, let screen = self.sharedScreen else { return }
            let right = item.button?.window.map { $0.frame.maxX - screen.frame.minX } ?? 0
            if right == previous || reads >= 5 { then(right) }
            else { self.settled(item, generation: generation, previous: right, reads: reads + 1, then: then) }
        }
    }
    private func finish(_ found: Search) {
        search = nil; placedAt = ProcessInfo.processInfo.systemUptime
        clearsGap = found.low != nil; placedSpare = nil; driftSeconds = 0
        placement = (found.low, found.trials)
        // When even the rightmost slot is left of the gap's right edge, the
        // icons under the housing can't move; the leftmost slot still keeps
        // icons added later out of it. The length is fitted once a second.
        item = makeItem(position: found.low ?? Self.positionLimit)
        if found.low == nil { NativeLog.session.notice("status items already reach past the viewer's camera; menu bar gap starts left of them") }
    }
    /// The length that reaches from the item's right edge to the gap's left
    /// edge. Its window is wider than its length by the menu bar's spacing
    /// (16 points on macOS 27), measured each time.
    private func fit(_ item: NSStatusItem, right: CGFloat, padding: CGFloat, gap: (x: Int, width: Int)) {
        let length = max(1, (right - CGFloat(gap.x) - min(24, max(0, padding))).rounded(.up))
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
