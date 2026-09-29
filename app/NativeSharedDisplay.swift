import AppKit

/// The display a session shares: normally this Mac's own main display, or, on
/// the viewer's request, a virtual display of the viewer's size that becomes
/// the main display. On a headless Mac it replaces macOS's placeholder; any
/// real monitors mirror it. Releasing it restores the previous arrangement,
/// and macOS also removes it if MacLink quits. Main thread.
final class NativeSharedDisplay {
    static var isAvailable: Bool { MLVirtualDisplay.isAvailable }
    private var virtual: MLVirtualDisplay?
    private var mirrored: [CGDirectDisplayID] = []
    private var generation: UInt64 = 0
    /// Points and scale of the display in use; nil when sharing the Mac's own.
    private(set) var size: (width: Int, height: Int, scale: Int)?

    /// Creates or resizes the virtual display, or releases it for an all-zero
    /// request. Calls `completion` on main once macOS has applied it.
    func apply(width: Int, height: Int, scale: Int, completion: @escaping (Bool) -> Void) {
        generation &+= 1
        guard width > 0, height > 0 else { release(); completion(true); return }
        if let size, size == (width, height, scale) { completion(true); return }
        let points = (UInt32(width), UInt32(height), UInt32(scale))
        if let virtual {
            guard virtual.resize(toPointWidth: points.0, pointHeight: points.1, scale: points.2) else { completion(false); return }
        } else {
            guard let created = MLVirtualDisplay(name: "MacLink", pointWidth: points.0, pointHeight: points.1, scale: points.2) else {
                completion(false); return
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
        guard generation == self.generation, let id = virtual?.displayID, id != kCGNullDirectDisplay else { return }
        let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary)
            as? [CGDisplayMode] ?? []
        let pixelWidth = width * scale, pixelHeight = height * scale
        let wanted = modes.first { (mode: CGDisplayMode) -> Bool in
            mode.width == width && mode.height == height && mode.pixelWidth == pixelWidth && mode.pixelHeight == pixelHeight
        }
        guard CGDisplayIsOnline(id) != 0, let wanted else {
            guard attempt < 30 else { completion(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.configure(width: width, height: height, scale: scale, attempt: attempt + 1, generation: generation, completion: completion)
            }
            return
        }
        if let current = CGDisplayCopyDisplayMode(id), current.pixelWidth != wanted.pixelWidth || current.width != wanted.width {
            guard CGDisplaySetDisplayMode(id, wanted, nil) == .success else { completion(false); return }
        }
        var mirrors: [CGDirectDisplayID] = []
        let others = Self.activeDisplays().filter { $0 != id && CGDisplayMirrorsDisplay($0) != id }
        if !others.isEmpty {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else { completion(false); return }
            for other in others where CGConfigureDisplayMirrorOfDisplay(config, other, id) == .success { mirrors.append(other) }
            guard CGCompleteDisplayConfiguration(config, .forAppOnly) == .success else { completion(false); return }
        }
        mirrored = Array(Set(mirrored + mirrors))
        size = (width, height, scale)
        completion(true)
    }

    /// Unmirrors any real monitors, then removes the virtual display.
    func release() {
        generation &+= 1
        if !mirrored.isEmpty {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let config {
                for display in mirrored { CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay) }
                CGCompleteDisplayConfiguration(config, .forAppOnly)
            }
            mirrored = []
        }
        virtual = nil; size = nil
    }

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }
}
