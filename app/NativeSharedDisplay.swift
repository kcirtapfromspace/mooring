import AppKit

/// The display a session shares: normally this Mac's own main display, or, on
/// the viewer's request, a virtual display of the viewer's size that becomes
/// the main display. On a headless Mac it replaces macOS's placeholder; any
/// real monitors mirror it. Releasing it restores the previous arrangement,
/// and macOS also removes it if MacLink quits. Main thread.
final class NativeSharedDisplay {
    static var isAvailable: Bool { MLVirtualDisplay.isAvailable }
    private var virtual: MLVirtualDisplay?
    private let topology: NativeDisplayTopology
    private var generation: UInt64 = 0
    /// Points and scale of the display in use; nil when sharing the Mac's own.
    private(set) var size: (width: Int, height: Int, scale: Int)?

    init(topology: NativeDisplayTopology = NativeDisplayTopology()) { self.topology = topology }

    /// True when applying this request would change the display macOS shows.
    func changes(width: Int, height: Int, scale: Int) -> Bool {
        guard width > 0, height > 0 else { return virtual != nil || topology.restorationPending }
        guard let size else { return true }
        return size != (width, height, scale)
    }

    /// Creates or resizes the virtual display, or releases it for an all-zero
    /// request. Calls `completion` on main once macOS has applied it.
    func apply(width: Int, height: Int, scale: Int, completion: @escaping (Bool) -> Void) {
        generation &+= 1
        guard width > 0, height > 0 else { completion(release()); return }
        if let size, size == (width, height, scale) { completion(true); return }
        let points = (UInt32(width), UInt32(height), UInt32(scale))
        if let virtual {
            guard virtual.resize(toPointWidth: points.0, pointHeight: points.1, scale: points.2) else { fail(completion); return }
        } else {
            guard topology.capture() else { completion(false); return }
            guard let created = MLVirtualDisplay(name: "MacLink", pointWidth: points.0, pointHeight: points.1, scale: points.2) else {
                fail(completion); return
            }
            virtual = created
        }
        configure(width: width, height: height, scale: scale, attempt: 0, generation: generation, completion: completion)
    }

    /// macOS brings a new display online asynchronously; wait up to 3 s for
    /// the exact Retina mode (normally already the default), select it if
    /// needed, and mirror other displays into it. Changes apply for this app
    /// only, so macOS undoes them if MacLink quits.
    private func configure(width: Int, height: Int, scale: Int, attempt: Int, generation: UInt64,
                           completion: @escaping (Bool) -> Void) {
        guard generation == self.generation, let virtual else { return }
        let id = virtual.displayID
        let modes = id == kCGNullDirectDisplay ? []
            : CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
        let pixelWidth = width * scale, pixelHeight = height * scale
        let wanted = modes.first { (mode: CGDisplayMode) -> Bool in
            mode.width == width && mode.height == height && mode.pixelWidth == pixelWidth && mode.pixelHeight == pixelHeight
        }
        guard id != kCGNullDirectDisplay, CGDisplayIsOnline(id) != 0, let wanted else {
            guard attempt < 30 else { fail(completion); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.configure(width: width, height: height, scale: scale, attempt: attempt + 1, generation: generation, completion: completion)
            }
            return
        }
        if let current = CGDisplayCopyDisplayMode(id), current.pixelWidth != wanted.pixelWidth || current.width != wanted.width {
            guard CGDisplaySetDisplayMode(id, wanted, nil) == .success else { fail(completion); return }
        }
        guard topology.mirror(to: id) else { fail(completion); return }
        size = (width, height, scale)
        completion(true)
    }

    /// Restores the original physical modes, origins and mirror relationships,
    /// then removes the virtual display. A failed restoration can be retried.
    @discardableResult func release() -> Bool {
        generation &+= 1
        let restored = topology.restoreWithRetry()
        virtual = nil; size = nil
        return restored
    }
    private func fail(_ completion: (Bool) -> Void) {
        release(); completion(false)
    }
}
