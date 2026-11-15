import AppKit

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}

final class ManualScheduler: ConnectionScheduling {
    var work: [() -> Void] = []
    func after(_ seconds: TimeInterval, _ action: @escaping () -> Void) { work.append(action) }
    func run() { let pending = work; work = []; pending.forEach { $0() } }
}
final class FakeTunnels: TunnelRunning {
    var onEvent: ((SavedMac, TunnelEvent) -> Void)?
    var onExit: ((SavedMac, Int32, String) -> Void)?
    var running = Set<String>()
    var stops = 0
    func isRunning(_ id: String) -> Bool { running.contains(id) }
    func open(_ mac: SavedMac, executable: URL, extraArguments: [String]) throws { running.insert(mac.id) }
    func stop(_ id: String) { running.remove(id); stops += 1 }
    func stopAll(wait: TimeInterval) { running.removeAll() }
}
final class FakeVNC: LinuxVNCConnecting {
    var opens = 0
    var closes = 0
    func signInNeeds(_ route: TunnelReady.Check) -> (Int32, Int32) { (0, Int32(ML_VNC_NEEDS_ACCOUNT)) }
    func signInAllowance(_ id: String) -> (Int32, UInt64, UInt32) { (0, 0, 2) }
    func open(_ id: String, port: UInt16, remoteHost: String, username: String, password: [UInt8]) -> (Int32, UInt64) { opens += 1; return (0, UInt64(opens)) }
    func close(_ session: UInt64) { closes += 1 }
}
final class FakeViewer: LinuxViewerPresenting {
    var sessionID: UInt64 = 1
    var isClosed = false
    var remotePixelsPerPoint: CGFloat?
    var extendsBesideCamera = false
    var onClose: (() -> Void)?
    var onDiagnosticBarChange: ((Bool) -> Void)?
    var onAllowSystemKeys: (() -> Void)?
    var onSignInRejected: ((String) -> Void)?
    var onEnded: ((String?) -> Void)?
    var onReconnect: (() -> Void)?
    func showDesktop(_ title: String) {}
    func showWindow(_ sender: Any?) {}
    func close() { isClosed = true; onClose?() }
    func end(_ message: String?) { sessionID = 0 }
}

final class Journal {
    var entries: [String] = []
}
enum Rejected: Error { case storage }
final class FakeVault: NativeCredentialVault {
    let journal: Journal
    var identity: NativeHostIdentity?
    var refusesDeletion = false
    init(_ journal: Journal) { self.journal = journal }
    func hostIdentity() throws -> NativeHostIdentity? { journal.entries.append("read identity"); return identity }
    func saveHostIdentity(_ identity: NativeHostIdentity) throws { journal.entries.append("save identity"); self.identity = identity }
    func peerCode(_ peerID: String) throws -> NativePairingCode? { nil }
    func peerDeviceKey(_ peerID: String) throws -> NativeDeviceKey { throw Rejected.storage }
    func savePeerCode(_ code: NativePairingCode, deviceKey: NativeDeviceKey?) throws {}
    func deletePeerCode(_ peerID: String) throws {
        journal.entries.append("delete credential")
        if refusesDeletion { throw Rejected.storage }
    }
}
struct FakePeers: NativePeerRepository {
    let journal: Journal
    func load() throws -> [NativePeer] { journal.entries.append("load peers"); return [] }
    func remember(_ code: NativePairingCode, tried: [String]) throws -> NativePeer { NativePeer(code: code, address: tried[0]) }
    func connected(_ id: String, through address: String) throws {}
    func forget(_ id: String) throws { journal.entries.append("forget peer") }
    func importLegacy(_ data: Data) throws {}
}
struct FakeDevices: NativeDeviceRepository {
    let journal: Journal
    let directory: String? = nil
    func prepare(acceptOldCode: Bool) throws { journal.entries.append("prepare devices") }
    func load() throws -> (devices: [NativeDevice], legacy: NativeLegacyState) { ([], NativeLegacyState()) }
    func remove(_ id: String) throws {}
    func stopOldCode() throws {}
    func extendOldCode() throws {}
    func reset() throws { journal.entries.append("reset devices") }
}

@main
struct WorkflowTests {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let suite = "dev.mooring.workflow-tests.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = ManualScheduler(), tunnels = FakeTunnels(), client = FakeVNC()
        let mac = SavedMac(id: "fixture", name: "Linux", host: "127.0.0.1", port: 5900, server: "vnc", ssh: .init(target: "fixture"))
        var answers: [(LinuxSignInAnswer?) -> Void] = []
        var viewers: [FakeViewer] = []
        let workflow = LinuxConnectionWorkflow(tunnels: tunnels, client: client, scheduler: scheduler, defaults: defaults,
            executable: { URL(fileURLWithPath: "/fixture/mooring") },
            makeViewer: { _, _, _ in let viewer = FakeViewer(); viewers.append(viewer); return viewer },
            prompt: { _, _, _, complete in answers.append(complete) }, activate: {})
        let ready = TunnelEvent.ready(TunnelReady(localPort: 1234, check: .init(remoteHost: "127.0.0.1", securityTypes: [129])))
        let desktop = TunnelEvent.desktop(RemoteDesktop(sessionUser: "fixture", title: "Unlocked", message: "Clean desktop", lock: "unlocked"))
        workflow.connect(mac)
        tunnels.onEvent?(mac, ready)
        tunnels.onEvent?(mac, desktop)
        scheduler.run()
        expect(answers.count == 1, "desktop/timeout race must prompt only once")
        tunnels.onEvent?(mac, .closed("cancelled"))
        answers[0]((username: "fixture", password: [1, 2]))
        expect(client.opens == 0, "a late credential callback must not connect after closure")
        tunnels.running.remove(mac.id)
        workflow.connect(mac)
        tunnels.onEvent?(mac, ready)
        tunnels.onEvent?(mac, .failed(ConnectionFailure(kind: "io", message: "fixture failure")))
        scheduler.run()
        expect(answers.count == 1, "closed attempt must cancel delayed sign-in")
        tunnels.running.remove(mac.id)
        workflow.connect(mac)
        tunnels.onEvent?(mac, ready)
        scheduler.run()
        expect(answers.count == 2, "a fresh attempt can prompt again")
        answers[1]((username: "fixture", password: [1]))
        expect(client.opens == 1 && viewers.count == 1, "submission opens one viewer")
        viewers[0].onSignInRejected?("fixture rejection")
        expect(client.opens == 1 && answers.count == 3, "rejection may prompt but never resubmit credentials automatically")
        answers[2](nil)
        expect(tunnels.stops > 0, "canceling sign-in stops the tunnel")
        workflow.stop()
        expect(tunnels.running.isEmpty, "shutdown releases every tunnel")

        let reconnect = NativeReconnectWorkflow(scheduler: scheduler)
        var retryCalls = 0
        _ = reconnect.schedule { retryCalls += 1 }
        reconnect.cancelPending(); scheduler.run()
        expect(retryCalls == 0 && !reconnect.isPending, "canceled native reconnect effects must not run")
        reconnect.reset()
        for _ in 0..<Int(ML_RECONNECT_ATTEMPTS) {
            expect(reconnect.schedule { retryCalls += 1 } != nil, "normal reconnect budget is available")
            scheduler.run()
        }
        expect(reconnect.schedule {} == nil, "reconnect budget is bounded")
        reconnect.awaitingPeer = true
        expect(reconnect.schedule {}?.limit == Int(ML_UPDATE_RECONNECT_ATTEMPTS), "updates use the distinct Rust budget")
        reconnect.reset(); scheduler.run()

        // The actual coordinator is compiled and exercised with fake effects.
        let journal = Journal()
        let sharedVault = FakeVault(journal)
        let deps = NativeSessionDependencies(defaults: defaults, credentials: sharedVault, peers: FakePeers(journal: journal),
            devices: FakeDevices(journal: journal), scheduler: scheduler, uptime: { 123 })
        let coordinator = NativeSessionCoordinator(dependencies: deps)
        expect(!coordinator.started && journal.entries.isEmpty, "composition must not start background services or touch credentials")
        coordinator.sharesAutomatically = true
        expect(defaults.bool(forKey: "native.shareAutomatically"), "preferences use the injected store")
        sharedVault.refusesDeletion = true
        do { try coordinator.forget(peerID: "fixture"); fatalError("expected refusal") } catch Rejected.storage {}
        expect(journal.entries == ["delete credential"], "failed credential erasure must preserve the catalog row")
        journal.entries = []; sharedVault.refusesDeletion = false
        try coordinator.forget(peerID: "fixture")
        expect(journal.entries == ["delete credential", "forget peer", "load peers"], "credentials are erased before metadata")
        journal.entries = []
        _ = try coordinator.preparedHostIdentity()
        expect(journal.entries == ["read identity", "reset devices", "save identity", "prepare devices"], "a new identity clears old approvals before being saved")
        journal.entries = []
        _ = try coordinator.preparedHostIdentity()
        expect(journal.entries == ["read identity", "prepare devices"], "existing identity and approved devices survive reuse")

        for invalid in [#"{"event":"ready","local_port":0,"check":{"remote_host":"127.0.0.1","security_types":[129]}}"#,
                        #"{"event":"ready","local_port":1234}"#,
                        #"{"event":"desktop","title":"x"}"#] {
            do { _ = try TunnelEvent.decode(Data(invalid.utf8)); fatalError("accepted invalid event") } catch is DecodingError {}
        }
        if case .ignored = try TunnelEvent.decode(Data(#"{"event":"future_event"}"#.utf8)) {} else { fatalError("unknown events should be forward compatible") }
        if case .ready(let payload) = try TunnelEvent.decode(Data(#"{"event":"ready","local_port":1234,"check":{"remote_host":"127.0.0.1","security_types":[129]}}"#.utf8)) {
            expect(payload.check.securityTypes == [129], "Rust JSON field names decode without dictionaries")
        } else { fatalError("expected ready") }
        // Exercise the real subprocess adapter, including pipe backpressure.
        // The fixture never invokes SSH or opens a network socket.
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("mooring-process-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let program = """
        #!/usr/bin/python3
        import sys
        sys.stderr.write('x' * 100000)
        sys.stderr.flush()
        print('{"event":"ready","local_port":1234,"check":{"remote_host":"127.0.0.1","security_types":[129]}}', flush=True)
        print('{"event":"closed","reason":"cancelled"}', flush=True)
        """
        try Data(program.utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let processTunnels = SSHTunnels()
        var processReady = false, processExited = false
        processTunnels.onEvent = { _, event in if case .ready = event { processReady = true } }
        processTunnels.onExit = { _, status, message in
            expect(status == 0 && message.utf8.count == 16384, "stderr is bounded and drained concurrently")
            processExited = true
        }
        try processTunnels.open(mac, executable: fixture)
        let deadline = Date().addingTimeInterval(10)
        while !processExited && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        if !processExited { processTunnels.stopAll(wait: 1) }
        expect(processReady && processExited && !processTunnels.isRunning(mac.id), "real tunnel process delivers typed events before exit without deadlocking")

        print("Application workflow tests passed: lifecycle races, cancellation, explicit sign-in, cleanup, identity and storage ordering, typed contracts.")
    }
}
