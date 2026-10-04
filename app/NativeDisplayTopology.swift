import CoreGraphics
import Foundation

/// Retained public CoreGraphics state, captured before creating a virtual
/// display. Online displays include mirror members that are not active.
struct NativeDisplaySnapshot {
    let id: CGDirectDisplayID
    let mirror: CGDirectDisplayID
    let x: Int32
    let y: Int32
    let mode: CGDisplayMode?
}

protocol NativeDisplayConfiguration {
    func onlineDisplays() -> [CGDirectDisplayID]?
    func snapshot(_ id: CGDirectDisplayID) -> NativeDisplaySnapshot?
    func mirror(_ displays: [CGDirectDisplayID], to target: CGDirectDisplayID) -> Bool
    func restore(_ snapshots: [NativeDisplaySnapshot]) -> Bool
}

/// Owns the original topology across resizes, with transactional rollback.
/// The backend is injectable so CI never needs to create or rearrange displays.
final class NativeDisplayTopology {
    private let configuration: NativeDisplayConfiguration
    private var original: [CGDirectDisplayID: NativeDisplaySnapshot] = [:]
    private var captured = false
    private var restorationEpoch: UInt64 = 0
    private(set) var restorationPending = false
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    init(configuration: NativeDisplayConfiguration = NativeDisplaySystem(),
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.configuration = configuration; self.schedule = schedule
    }

    func capture() -> Bool {
        // A new session cannot adopt the physical state of failed cleanup.
        if restorationPending && !restore() { return false }
        if captured { return true }
        guard let online = configuration.onlineDisplays(), let states = snapshots(online) else { return false }
        original = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0) }); captured = true
        return true
    }

    func mirror(to target: CGDirectDisplayID) -> Bool {
        guard captured, let online = configuration.onlineDisplays(),
              let before = snapshots(online.filter { $0 != target }) else { return false }
        for state in before where original[state.id] == nil {
            // A hotplugged display already mirroring our ephemeral target has
            // no pre-session physical master to restore; unmirror it on exit.
            original[state.id] = NativeDisplaySnapshot(id: state.id, mirror: state.mirror == target ? kCGNullDirectDisplay : state.mirror,
                                                       x: state.x, y: state.y, mode: state.mode)
        }
        let changed = before.filter { $0.mirror != target }
        guard !changed.isEmpty else { return true }
        guard configuration.mirror(changed.map { $0.id }, to: target) else {
            // A failed completion may have changed system state; undo this
            // attempt, preserving the original snapshot for final release.
            _ = configuration.restore(before)
            return false
        }
        return true
    }

    @discardableResult func restore() -> Bool {
        guard captured else { return true }
        restorationPending = true
        guard let displays = configuration.onlineDisplays() else { return false }
        let online = Set(displays)
        let states = original.values.filter { online.contains($0.id) }.map {
            NativeDisplaySnapshot(id: $0.id, mirror: online.contains($0.mirror) ? $0.mirror : kCGNullDirectDisplay,
                                  x: $0.x, y: $0.y, mode: $0.mode)
        }.sorted { $0.id < $1.id }
        guard states.isEmpty || configuration.restore(states) else { return false }
        original = [:]; captured = false; restorationPending = false; restorationEpoch &+= 1
        return true
    }

    /// Teardown callers need no live session to finish cleanup. Retry transient
    /// system refusals for 5 s; retain the snapshot for a later explicit retry
    /// if the system remains unavailable. Each generation has one live retry.
    @discardableResult func restoreWithRetry() -> Bool {
        restorationEpoch &+= 1
        let epoch = restorationEpoch
        guard !restore() else { return true }
        retryRestoration(epoch: epoch, remaining: 10)
        return false
    }
    private func retryRestoration(epoch: UInt64, remaining: Int) {
        schedule(0.5) { [weak self] in
            guard let self, self.restorationPending, self.restorationEpoch == epoch else { return }
            if !self.restore(), remaining > 1 { self.retryRestoration(epoch: epoch, remaining: remaining - 1) }
        }
    }

    private func snapshots(_ ids: [CGDirectDisplayID]) -> [NativeDisplaySnapshot]? {
        var states: [NativeDisplaySnapshot] = []
        for id in Set(ids).sorted() {
            guard let state = configuration.snapshot(id) else { return nil }
            states.append(state)
        }
        return states
    }
}

/// Every mutation is a public, app-only CoreGraphics configuration. Failed
/// staging cancels the uncompleted transaction; completion consumes it even
/// on failure, so it is never canceled or reused afterward.
struct NativeDisplaySystem: NativeDisplayConfiguration {
    func onlineDisplays() -> [CGDirectDisplayID]? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return Array(displays.prefix(Int(count)))
    }
    func snapshot(_ id: CGDirectDisplayID) -> NativeDisplaySnapshot? {
        guard CGDisplayIsOnline(id) != 0 else { return nil }
        let origin = CGDisplayBounds(id).origin
        guard let x = Int32(exactly: origin.x), let y = Int32(exactly: origin.y) else { return nil }
        return NativeDisplaySnapshot(id: id, mirror: CGDisplayMirrorsDisplay(id), x: x, y: y, mode: CGDisplayCopyDisplayMode(id))
    }
    func mirror(_ displays: [CGDirectDisplayID], to target: CGDirectDisplayID) -> Bool {
        transaction { config in
            for id in displays {
                guard CGConfigureDisplayMirrorOfDisplay(config, id, target) == .success else { return false }
            }
            return true
        }
    }
    func restore(_ snapshots: [NativeDisplaySnapshot]) -> Bool {
        transaction { config in
            // Clear temporary groups before restoring their original masters,
            // modes and origins. Rebuild the original mirror groups last.
            for state in snapshots {
                guard CGConfigureDisplayMirrorOfDisplay(config, state.id, kCGNullDirectDisplay) == .success else { return false }
            }
            for state in snapshots {
                if let mode = state.mode,
                   CGConfigureDisplayWithDisplayMode(config, state.id, mode, nil) != .success { return false }
                guard CGConfigureDisplayOrigin(config, state.id, state.x, state.y) == .success else { return false }
            }
            for state in snapshots where state.mirror != kCGNullDirectDisplay {
                guard CGConfigureDisplayMirrorOfDisplay(config, state.id, state.mirror) == .success else { return false }
            }
            return true
        }
    }
    private func transaction(_ stage: (CGDisplayConfigRef) -> Bool) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard stage(config) else { CGCancelDisplayConfiguration(config); return false }
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }
}
