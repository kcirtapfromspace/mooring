// Topology regression tests use an in-memory display backend only. No live
// CoreGraphics inspection, display creation, mode change or permission access.
import CoreGraphics

/// This test binary never links the private display boundary. Every private
/// operation fails immediately if a supposedly pure cleanup test reaches it.
final class MLVirtualDisplay {
    static var isAvailable: Bool { fatalError("Unexpected private display probe") }
    var displayID: CGDirectDisplayID { fatalError("Unexpected private display read") }
    init?(name: String, pointWidth: UInt32, pointHeight: UInt32, scale: UInt32) { fatalError("Unexpected private display creation") }
    func resize(toPointWidth: UInt32, pointHeight: UInt32, scale: UInt32) -> Bool { fatalError("Unexpected private display resize") }
}

final class MockDisplayConfiguration: NativeDisplayConfiguration {
    var states: [CGDirectDisplayID: NativeDisplaySnapshot] = [:]
    var listFails = false, mirrorFailsPartway = false, restoreFails = false
    var mirrorCalls = 0, restoreCalls = 0
    var lastRestored: [NativeDisplaySnapshot] = []
    func onlineDisplays() -> [CGDirectDisplayID]? { listFails ? nil : states.keys.sorted() }
    func snapshot(_ id: CGDirectDisplayID) -> NativeDisplaySnapshot? { states[id] }
    func mirror(_ displays: [CGDirectDisplayID], to target: CGDirectDisplayID) -> Bool {
        mirrorCalls += 1
        for id in displays {
            states[id] = NativeDisplaySnapshot(id: id, mirror: target, x: 0, y: 0, mode: states[id]?.mode)
            if mirrorFailsPartway { return false }
        }
        return true
    }
    func restore(_ snapshots: [NativeDisplaySnapshot]) -> Bool {
        restoreCalls += 1
        if restoreFails { return false }
        lastRestored = snapshots
        for state in snapshots { states[state.id] = state }
        return true
    }
    func add(_ id: CGDirectDisplayID, mirror: CGDirectDisplayID = 0, x: Int32 = 0, y: Int32 = 0) {
        states[id] = NativeDisplaySnapshot(id: id, mirror: mirror, x: x, y: y, mode: nil)
    }
}

@main enum NativeDisplayTests {
    static var checks = 0
    static func require(_ value: Bool, _ message: String) {
        checks += 1
        if !value { fatalError(message) }
    }
    static func fixture() -> (MockDisplayConfiguration, NativeDisplayTopology) {
        let backend = MockDisplayConfiguration()
        backend.add(1, x: -1920); backend.add(2, mirror: 1, x: -1920); backend.add(3, x: 2560, y: 50)
        return (backend, NativeDisplayTopology(configuration: backend))
    }
    static func main() {
        let (backend, topology) = fixture()
        require(topology.capture(), "Capture original physical topology before virtual creation")
        backend.add(99)
        require(topology.mirror(to: 99), "Physical and inactive mirror members join the virtual display")
        require([1, 2, 3].allSatisfy { backend.states[UInt32($0)]?.mirror == 99 }, "Every online physical display was included")
        require(topology.capture() && topology.mirror(to: 99) && backend.mirrorCalls == 1, "Resize preserves the first snapshot and avoids redundant changes")
        backend.add(4, x: 5000)
        require(topology.mirror(to: 99), "A newly attached display is included")
        require(topology.restore(), "Restore succeeds")
        require(backend.states[1]?.mirror == 0 && backend.states[2]?.mirror == 1 && backend.states[3]?.mirror == 0,
                "Original physical mirror relationships are restored")
        require(backend.states[1]?.x == -1920 && backend.states[3]?.x == 2560 && backend.states[3]?.y == 50,
                "Original physical origins are restored")
        require(backend.states[4]?.mirror == 0 && backend.states[4]?.x == 5000, "Hotplugged displays retain their own pre-mirror arrangement")
        let restores = backend.restoreCalls
        require(topology.restore() && backend.restoreCalls == restores, "Release is idempotent")

        let (failed, failureTopology) = fixture()
        require(failureTopology.capture(), "Capture failure fixture")
        failed.add(99); failed.mirrorFailsPartway = true
        require(!failureTopology.mirror(to: 99), "A partial mirror failure rejects the request")
        require(failed.states[1]?.mirror == 0 && failed.states[2]?.mirror == 1 && failed.states[3]?.x == 2560,
                "Partial system changes roll back to the state before the attempt")
        failed.mirrorFailsPartway = false
        require(failureTopology.mirror(to: 99), "A request can succeed after rollback")
        failed.restoreFails = true
        require(!failureTopology.restore(), "Restore failure is reported")
        failed.restoreFails = false
        require(failureTopology.restore() && failed.states[2]?.mirror == 1, "Failed cleanup retains the original snapshot for retry")

        let (hotplugFailure, hotplugTopology) = fixture()
        require(hotplugTopology.capture(), "Capture hotplug rollback fixture")
        hotplugFailure.add(99); require(hotplugTopology.mirror(to: 99), "Mirror before hotplug failure")
        hotplugFailure.add(4, x: 5000)
        hotplugFailure.mirrorFailsPartway = true; hotplugFailure.restoreFails = true
        require(!hotplugTopology.mirror(to: 99), "Reject failed hotplug configuration even if rollback also fails")
        hotplugFailure.mirrorFailsPartway = false; hotplugFailure.restoreFails = false
        require(hotplugTopology.restore() && hotplugFailure.states[4]?.mirror == 0 && hotplugFailure.states[4]?.x == 5000,
                "Release retains hotplug state across both configuration and rollback failures")

        let (automatic, automaticTopology) = fixture()
        require(automaticTopology.capture(), "Capture automatically mirrored hotplug fixture")
        automatic.add(99); require(automaticTopology.mirror(to: 99), "Mirror automatic hotplug fixture")
        automatic.add(4, mirror: 99, x: 5000)
        require(automaticTopology.mirror(to: 99), "Remember a new display already mirroring the ephemeral target")
        automatic.states.removeValue(forKey: 99)
        require(automaticTopology.restore() && automatic.states[4]?.mirror == 0 && automatic.states[4]?.x == 5000,
                "A new display never retains a removed virtual display as its mirror master")

        let (retryBackend, _) = fixture()
        var scheduled: [() -> Void] = []
        let retryTopology = NativeDisplayTopology(configuration: retryBackend, schedule: { _, work in scheduled.append(work) })
        require(retryTopology.capture(), "Capture asynchronous cleanup fixture")
        retryBackend.add(99); require(retryTopology.mirror(to: 99), "Mirror asynchronous cleanup fixture")
        retryBackend.restoreFails = true
        require(!retryTopology.restoreWithRetry() && retryTopology.restorationPending && scheduled.count == 1,
                "Teardown retains pending cleanup and schedules one retry independently of the virtual display")
        require(!retryTopology.capture(), "A new session cannot adopt the state of failed cleanup")
        retryBackend.restoreFails = false; scheduled.removeFirst()()
        require(!retryTopology.restorationPending && retryBackend.states[2]?.mirror == 1 && scheduled.isEmpty,
                "A transient failure restores the original arrangement without a new session or request")

        require(retryTopology.capture(), "Capture bounded retry fixture")
        require(retryTopology.mirror(to: 99), "Mirror bounded retry fixture")
        retryBackend.restoreFails = true
        let beforeRetries = retryBackend.restoreCalls
        require(!retryTopology.restoreWithRetry(), "Start bounded cleanup failure")
        for _ in 0..<10 { require(scheduled.count == 1, "Exactly one retry is pending"); scheduled.removeFirst()() }
        require(scheduled.isEmpty && retryBackend.restoreCalls - beforeRetries == 11 && retryTopology.restorationPending,
                "Cleanup has a finite retry budget and retains state after exhaustion")
        retryBackend.restoreFails = false
        require(retryTopology.restoreWithRetry() && !retryTopology.restorationPending, "An explicit retry can complete exhausted cleanup")

        require(retryTopology.capture() && retryTopology.mirror(to: 99), "Capture stale retry fixture")
        retryBackend.restoreFails = true; require(!retryTopology.restoreWithRetry(), "Schedule a soon-obsolete retry")
        retryBackend.restoreFails = false
        require(retryTopology.capture() && retryTopology.mirror(to: 99), "Finish cleanup before adopting a new session")
        let newSessionRestores = retryBackend.restoreCalls
        scheduled.removeFirst()()
        require(retryBackend.restoreCalls == newSessionRestores && retryBackend.states[2]?.mirror == 99,
                "An old cleanup callback never alters the new session")

        let (teardownBackend, _) = fixture()
        var teardownRetries: [() -> Void] = []
        let teardownTopology = NativeDisplayTopology(configuration: teardownBackend, schedule: { _, work in teardownRetries.append(work) })
        let shared = NativeSharedDisplay(topology: teardownTopology)
        require(teardownTopology.capture(), "Capture production teardown fixture")
        teardownBackend.add(99); require(teardownTopology.mirror(to: 99), "Mirror production teardown fixture")
        teardownBackend.restoreFails = true
        require(!shared.release() && shared.size == nil, "Release removes virtual ownership after failed restoration")
        require(shared.changes(width: 0, height: 0, scale: 0), "A zero-size request can retry pending cleanup even without a virtual display")
        var zeroResult: Bool?
        shared.apply(width: 0, height: 0, scale: 0) { zeroResult = $0 }
        require(zeroResult == false, "A failed zero-size restoration reports failure")
        teardownBackend.restoreFails = false
        for retry in teardownRetries { retry() }
        require(teardownBackend.states[2]?.mirror == 1 && !shared.changes(width: 0, height: 0, scale: 0),
                "Production teardown restores a transient failure without a session and clears pending changes")

        let (unplugged, unpluggedTopology) = fixture()
        require(unpluggedTopology.capture(), "Capture unplug fixture")
        unplugged.add(99); require(unpluggedTopology.mirror(to: 99), "Mirror unplug fixture")
        unplugged.states.removeValue(forKey: 1)
        require(unpluggedTopology.restore(), "An unplugged original master does not prevent cleanup")
        require(unplugged.states[2]?.mirror == 0 && !unplugged.lastRestored.contains { $0.id == 1 },
                "Offline displays are skipped and unavailable mirror targets fall back to unmirrored")

        let (unreadable, unreadableTopology) = fixture()
        unreadable.listFails = true
        require(!unreadableTopology.capture() && unreadable.mirrorCalls == 0, "Do not mutate displays without a readable original topology")
        print("Native display topology: \(checks) mock checks passed; no live display actions.")
    }
}
