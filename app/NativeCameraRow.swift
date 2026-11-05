import AppKit

/// The row beside a camera housing while a viewer is full screen. Native full
/// screen keeps windows below the housing, and only a window above the menu
/// bar's level shows in this row. It never becomes key, so keyboard input
/// stays with the viewer, and its frame stays where it is put.
final class NativeCameraRow: NSWindow {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isReleasedWhenClosed = false; hasShadow = false; backgroundColor = .black
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        contentView = content
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// The camera housing's area in screen coordinates, or nil for a display without one.
    static func housing(on screen: NSScreen) -> NSRect? {
        guard screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        return NSRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top,
                      width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    }
}
