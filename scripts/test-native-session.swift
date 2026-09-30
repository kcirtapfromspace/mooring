// Swift session-boundary checks. Pairing, address, control and peer-store rules
// are Rust's (cargo test -p maclink-session); these cover the Swift wrappers.
// No Keychain access, live capture, input injection, or permission request.
// Pairing runs over a loopback-only ephemeral listener with a temporary device
// list; another is closed immediately to test channel queue state safely;
// peers use a temporary folder.
// Clipboard checks use a private, uniquely named pasteboard, never the user's.
// Built and run by scripts/test-native.sh, which links the arm64 Rust static library.
import AppKit
import CoreGraphics

@main
enum NativeSessionTests {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    static var checks = 0
    static func require(_ value: Bool, _ message: String) throws {
        checks += 1
        if !value { throw Failure(message) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch { checks += 1; return }
        throw Failure(message)
    }
    static func geometry(x: Double = -1920, y: Double = 0, width: Double = 1920, height: Double = 1080,
                         pixelsWide: Int = 1920, pixelsHigh: Int = 1080) -> NativeDisplayGeometry {
        NativeDisplayGeometry(x: x, y: y, width: width, height: height, pixelWidth: pixelsWide, pixelHeight: pixelsHigh)
    }
    static func drainMainQueue() {
        let delivered = Counter()
        DispatchQueue.main.async { delivered.increment() }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while delivered.value == 0 && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }
    final class Slot<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
    /// Connects while the listener accepts once: the viewer's result and the
    /// host's session, nil when the host refused.
    static func connectOnce(_ listener: NativeTransport, _ code: NativePairingCode, _ key: NativeDeviceKey)
        -> (Result<(NativeTransport, NativeTransport.Mode), Error>, NativeTransport?) {
        let host = Slot<NativeTransport>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { host.value = try? listener.accept(); done.signal() }
        let viewer = Result { try NativeTransport.connect(address: "127.0.0.1", code: code, deviceKey: key,
                                                          deviceName: "MacBook Pro", port: listener.listeningPort) }
        done.wait()
        return (viewer, host.value)
    }
    static func refused(_ result: Result<(NativeTransport, NativeTransport.Mode), Error>) -> Bool {
        if case .failure(let error) = result { return (error as? NativeSessionError)?.isAuthenticationFailure == true }
        return false
    }
    /// A one-time code approves this Mac's key, the saved pairing connects by
    /// it, and a removed Mac is refused. Loopback and a temporary list only.
    static func testDevicePairing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("maclink-devices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let devices = NativeDeviceStore(directory: folder.path)
        try devices.prepare(acceptOldCode: false)
        let identity = try NativeHostIdentity.create()
        let listener = try NativeTransport.listen(identity: identity, devices: devices, bindAddress: "127.0.0.1", port: 0)
        defer { listener.close() }
        let code = try NativePairingCode.forHost(address: "127.0.0.1", computerName: "Studio", identity: identity,
                                                 oneTimeSecret: listener.newPairingSecret())
        let key = try NativeDeviceKey.create()

        let (paired, host) = connectOnce(listener, code, key)
        let (viewer, mode) = try paired.get()
        let id = host?.peerDevice ?? ""
        try require(mode == .pair && mode.approvedKey && id.count == 64, "A one-time code approves this Mac's key")
        let approved = try devices.load()
        try require(approved.devices.map(\.id) == [id] && approved.devices.first?.name == "MacBook Pro"
                    && approved.devices.first?.migrated == false && !approved.legacy.accepted,
                    "The sharing Mac lists the approved Mac by name")
        viewer.close(); host?.close()
        let (reused, reusedHost) = connectOnce(listener, code, try NativeDeviceKey.create())
        try require(refused(reused) && reusedHost == nil && (try devices.load().devices.count) == 1, "A used code is refused")

        let saved = try code.device()
        let (returning, returningHost) = connectOnce(listener, saved, key)
        let (again, againMode) = try returning.get()
        try require(againMode == .device && !againMode.approvedKey && returningHost?.peerDevice == id,
                    "The saved pairing connects as the approved Mac")
        again.close(); returningHost?.close()
        try require(returningHost?.peerDevice == nil, "A closed session names no Mac")

        let file = try String(contentsOf: folder.appendingPathComponent("native-devices.json"), encoding: .utf8)
        for sensitive in [key.privateKey, identity.privateKey, identity.secret, code.secret] {
            try require(!file.contains(sensitive.base64EncodedString()), "The device list holds no private key or secret")
        }
        try devices.remove(id)
        let (removed, removedHost) = connectOnce(listener, saved, key)
        try require(refused(removed) && removedHost == nil, "A removed Mac is refused")
        try devices.reset()
        try require(try devices.load().devices.isEmpty, "Reset approves no one")
    }
    /// Clock placement and latency arithmetic; no session or display.
    static func testLatency() throws {
        // Every build announces what it always supports; self-tests add the rest.
        let always = UInt64(ML_CAPABILITY_CURSOR) | UInt64(ML_CAPABILITY_GESTURES) | UInt64(ML_CAPABILITY_LATENCY)
            | UInt64(ML_CAPABILITY_VERSION)
        try require(NativeCapabilities.local(hevc444: false, virtualDisplay: false, audio: false) == always,
                    "Pointer shapes, gestures, latency and versions are always announced")
        let everything = always | UInt64(ML_CAPABILITY_HEVC_444) | UInt64(ML_CAPABILITY_VIRTUAL_DISPLAY) | UInt64(ML_CAPABILITY_AUDIO)
            | UInt64(ML_CAPABILITY_REMOTE_UPDATE)
        try require(NativeCapabilities.local(hevc444: true, virtualDisplay: true, audio: true, updatesItself: true) == everything,
                    "Self-tested capabilities, and remote updates for release builds, are announced when they apply")
        // Versions compare by release, then build; development builds can't be ordered.
        let preview19 = NativeVersion(build: 24, release: 3 << 32 | 19), preview20 = NativeVersion(build: 25, release: 3 << 32 | 20)
        try require(preview19.compared(to: preview20) == .orderedAscending && preview20.compared(to: preview19) == .orderedDescending
                    && preview19.compared(to: preview19) == .orderedSame, "Later releases are newer")
        try require(preview19.compared(to: NativeVersion(build: 99, release: 0)) == nil, "A development build is never ordered")
        try require(preview19.name == "0.3.0 preview 19" && NativeVersion(build: 3, release: 0).name == "a development build",
                    "Versions read as people write them")
        try require(NativeVersion.local.release == 0 && NativeVersion.local.build >= 1,
                    "A build without an update feed reports as a development build")
        let sync = NativeClockSync()
        let frame = NativeFrameTiming(hostUs: 5_100_000, decodeStartUs: 112_000, decodedUs: 116_000, presentedUs: 130_000)
        try require(sync.latency(frame) == nil, "No latency before the clocks are placed")
        // The sharing Mac's clock is 5 s ahead; the queued 40 ms reply is not used.
        sync.add(sentUs: 0, receivedUs: 40_000, hostUs: 5_030_000)
        sync.add(sentUs: 50_000, receivedUs: 52_000, hostUs: 5_051_000)
        try require(sync.estimate?.offsetUs == 5_000_000 && sync.estimate?.errorUs == 1_000, "The fastest round trip places the clocks")
        let latency = sync.latency(frame)
        try require(latency?.total == 30 && latency?.toViewer == 12 && latency?.displayWait == 14,
                    "Latency runs from the host's screen change to this display")
        try require(sync.latency(NativeFrameTiming(hostUs: 5_200_000, decodeStartUs: 112_000, decodedUs: 116_000, presentedUs: 130_000)) == nil,
                    "A frame shown before its capture time is not counted")
        for index in 0..<40 { sync.add(sentUs: UInt64(index) * 1_000_000, receivedUs: UInt64(index) * 1_000_000 + 9_000, hostUs: 0) }
        try require(sync.estimate?.errorUs == 4_500, "Only the latest 16 replies count")
        sync.reset()
        try require(sync.estimate == nil, "A new session starts unplaced")
        // Host pacing: the send-buffer limit follows the fastest recent round trip.
        let flow = NativeFlowLimit()
        try require(flow.bytes == 131_072, "Pacing starts at the 128 KiB floor")
        func queue(_ roundTrip: UInt32, _ sent: UInt64) -> MLSendQueue {
            MLSendQueue(queued_bytes: 0, round_trip_ms: roundTrip, sent_bytes: sent, retransmitted_bytes: 0)
        }
        flow.update(queue(80, 1_000_000)); flow.update(queue(50, 4_000_000))
        try require(flow.bytes == 225_000, "3 MB a second at a 50 ms round trip allows 225 kB")
        flow.update(queue(400, 7_000_000))
        try require(flow.bytes == 225_000, "A slow round trip during a stall does not raise the limit")
        for _ in 0..<NativeFlowLimit.window { flow.update(queue(3, 7_000_000)) }
        try require(flow.bytes == 131_072, "Idle, and on a home network, the floor applies")
        flow.reset()
        try require(flow.bytes == 131_072, "A new session starts at the floor")
        var window = NativeLatencyWindow()
        try require(window.summary == nil, "No summary without frames")
        for value in 1...100 { window.add((Double(value), Double(value) / 2, 1)) }
        let summary = window.summary
        try require(summary?.p50 == 51 && summary?.p95 == 95 && summary?.toViewer == 25.5 && summary?.displayWait == 1,
                    "Median and 95th percentile")
        for _ in 0..<(NativeLatencyWindow.capacity * 2) { window.add((1, 1, 1)) }
        try require(window.totals.count == NativeLatencyWindow.capacity, "The window is bounded")
    }

    static func main() {
        do {
            try run()
            print("Native session tests passed: \(checks) checks; Rust pairing, per-Mac keys over loopback, peer store, control and display boundaries, cancellation, bounded delivery, diagnostics and the shared clipboard. Loopback only; no Keychain, capture, or input access.")
        } catch {
            fputs("Native session tests failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    static func run() throws {
        let publicKey = Data((0..<32).map { UInt8($0 + 1) })
        let secret = Data((0..<32).map { UInt8($0 + 101) })
        let privateKey = Data((0..<32).map { UInt8($0 + 201) })
        let identity = NativeHostIdentity(privateKey: privateKey, publicKey: publicKey, secret: secret)
        let code = try NativePairingCode.forHost(address: "Studio.local", computerName: " Studio\u{200D} Mac\n", identity: identity,
                                                 oneTimeSecret: secret)
        try require(code.address == "studio.local" && code.name == "Studio Mac", "Rust normalizes this Mac's address and name")
        try require(code.publicKey == publicKey && code.secret == secret && code.kind == .oneTime, "Pairing code carries exact credentials")
        try require(code.peerID.count == 64 && code.peerID.allSatisfy { "0123456789abcdef".contains($0) },
                    "Peer ID is a fixed lowercase public-key fingerprint")
        let encoded = try code.encoded()
        let decoded = try NativePairingCode.parse(" \n\t" + encoded + "\r\n ")
        try require(encoded.hasPrefix("MLP2.") && decoded.address == code.address && decoded.name == code.name
                     && decoded.peerID == code.peerID && decoded.secret == secret && decoded.kind == .oneTime,
                    "Pairing text round-trips through Rust")
        try rejects("A one-time code is never saved") { _ = try code.credential() }
        let device = try code.device()
        try require(device.kind == .device && device.secret == Data(count: 32) && device.peerID == code.peerID,
                    "The saved pairing keeps the sharing Mac's key and no secret")
        try rejects("A saved pairing is no code to share") { _ = try device.encoded() }
        let restored = try NativePairingCode.fromCredential(device.credential())
        try require(restored.peerID == code.peerID && restored.kind == .device, "Keychain credentials round-trip through Rust")
        let legacyObject: [String: Any] = ["version": 1, "address": "studio.local", "name": "Studio Mac",
                                           "publicKey": publicKey.base64EncodedString(), "secret": secret.base64EncodedString()]
        let legacy = try NativePairingCode.fromCredential(JSONEncoder().encode(LegacyCredential(object: legacyObject)))
        try require(legacy.peerID == code.peerID && legacy.kind == .legacy && legacy.secret == secret,
                    "Credentials saved by the earlier Swift encoder remain readable")
        for malformed in ["", "MLP1.not base64!", String(encoded.dropFirst(5)), "MLP1." + String(encoded.dropFirst(5)),
                          "MLP3." + String(encoded.dropFirst(5))] {
            try rejects("Pairing parser rejects malformed text") { _ = try NativePairingCode.parse(malformed) }
        }
        try rejects("Credential decoder rejects malformed data") { _ = try NativePairingCode.fromCredential(Data("{}".utf8)) }
        try require(NativePairingCode.normalizedAddress("[::1]") == "::1" && NativePairingCode.normalizedAddress("STUDIO.local") == "studio.local",
                    "Addresses use the shared normalized host rule")
        for address in ["", "vnc://studio.local", "user@studio.local", "host:5900", "127.1", "fe80::1%en0"] {
            try require(NativePairingCode.normalizedAddress(address) == nil, "Reject unsupported address \(address)")
        }
        try identity.validate()
        for badIdentity in [
            NativeHostIdentity(privateKey: Data(), publicKey: publicKey, secret: secret),
            NativeHostIdentity(privateKey: privateKey, publicKey: Data(repeating: 0, count: 33), secret: secret),
            NativeHostIdentity(privateKey: privateKey, publicKey: publicKey, secret: Data(repeating: 0, count: 31))
        ] { try rejects("Host identity must validate every key length") { try badIdentity.validate() } }
        let generated = try NativeHostIdentity.create()
        try generated.validate()
        try require(generated.privateKey != generated.publicKey && generated.privateKey != generated.secret,
                    "Identity material is not reused across roles")
        let earlier = try JSONDecoder().decode(NativeHostIdentity.self, from: JSONEncoder().encode(identity))
        try require(earlier.listsDevices == nil && generated.listsDevices == true,
                    "An identity saved by an earlier version may accept its old code; a new one never does")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("maclink-peers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NativePeerStore(directory: folder.path)
        try require(try store.load().isEmpty, "A missing peer store is empty")
        let legacyPeers = try JSONSerialization.data(withJSONObject: [["id": String(repeating: "a", count: 64), "name": "Old Mac", "address": "old.local"]])
        try store.importLegacy(legacyPeers)
        let peer = try store.remember(code, address: "Studio.Local")
        try require(peer.id == code.peerID && peer.address == "studio.local", "Remembered peers use the Rust ID and address rule")
        try require(try store.load().map(\.name) == ["Studio Mac", "Old Mac"], "Most recent peer first after legacy import")
        try rejects("Invalid addresses are not saved") { try store.remember(code, address: "http://studio.local") }
        let peerFile = try String(contentsOf: folder.appendingPathComponent("native-peers.json"), encoding: .utf8)
        for sensitive in [secret.base64EncodedString(), privateKey.base64EncodedString(), publicKey.base64EncodedString(), "secret"] {
            try require(!peerFile.contains(sensitive), "Saved peer metadata contains no key or secret material")
        }

        let display = geometry()
        try require(display.isValid, "A standard negative-origin display is valid")
        for invalid in [geometry(x: .nan), geometry(width: 0), geometry(pixelsWide: 1921), geometry(pixelsWide: -2), geometry(pixelsHigh: Int.max)] {
            try require(!invalid.isValid, "Display bounds come from Rust")
        }
        for message: NativeControlMessage in [.geometry(display, inputEnabled: true), .inputState(enabled: false),
                                              .ping(0), .pong(UInt64.max), .keyframe, .clock(7, hostUs: 0x0123_4567_89AB_CDEF),
                                              .version(NativeVersion(build: 24, release: 3 << 32 | 19)), .updateRequest,
                                              .updateStatus(.checking, ready: nil),
                                              .updateStatus(.ready, ready: NativeVersion(build: 25, release: 3 << 32 | 20))] {
            try require(try NativeControlMessage(validated: message.raw) == message, "Every control message round-trips the C ABI")
        }
        try testLatency()
        var unknown = MLControlMessage(); unknown.kind = 12
        try rejects("Unknown control kinds are rejected") { _ = try NativeControlMessage(validated: unknown) }

        try testTelemetry()
        try testClipboard()
        try testDevicePairing()

        let token = NativeRunToken()
        try require(token.isActive, "Run token begins active")
        let winners = Counter()
        DispatchQueue.concurrentPerform(iterations: 128) { _ in if token.cancel() { winners.increment() } }
        try require(winners.value == 1 && !token.isActive, "Exactly one concurrent cancellation wins")
        try require(!token.cancel() && !token.isActive, "Cancellation is permanent and idempotent")

        // A closed local listener gives us a transport wrapper without opening a
        // remote session. Main-queue admission does not use the underlying I/O.
        let closedTransport = try NativeTransport.listen(identity: generated, devices: NativeDeviceStore(directory: folder.path),
                                                         bindAddress: "127.0.0.1", port: 0)
        try require(closedTransport.listeningPort > 0, "Queue fixture binds only an ephemeral loopback listener")
        closedTransport.close()
        let healthyChannel = NativeSessionChannel(closedTransport)
        let delivered = Counter()
        for _ in 0..<16 { healthyChannel.deliverControl { delivered.increment() } }
        try require(healthyChannel.token.isActive, "Exactly sixteen queued main-thread controls are admitted")
        drainMainQueue()
        try require(delivered.value == 16, "Accepted control callbacks are delivered once")
        healthyChannel.deliverControl { delivered.increment() }
        drainMainQueue()
        try require(delivered.value == 17 && healthyChannel.token.isActive, "Delivery releases queue slots")
        healthyChannel.close()
        healthyChannel.deliverControl { delivered.increment() }
        drainMainQueue()
        try require(delivered.value == 17, "Closed channels reject new main-thread callbacks")
        let overloadedChannel = NativeSessionChannel(closedTransport)
        let invalidated = Counter(), failures = Counter()
        overloadedChannel.onFailure = { _ in failures.increment() }
        for _ in 0..<17 { overloadedChannel.deliverControl { invalidated.increment() } }
        try require(!overloadedChannel.token.isActive, "The seventeenth pending control closes the connection")
        drainMainQueue()
        try require(invalidated.value == 0 && failures.value == 1, "Overload cancels queued work and reports one failure")
        let completions = Counter()
        overloadedChannel.send(.input(try NativeInputEvent(kind: .releaseAll))) { completions.increment() }
        try require(completions.value == 1, "Send rejection still releases its completion ownership exactly once")
        overloadedChannel.fail("repeated failure")
        drainMainQueue()
        try require(failures.value == 1, "Repeated channel failure remains idempotent")

        let measurements = NativeSessionMeasurements()
        measurements.set("network_round_trip_ms", 12.5)
        measurements.set("network_round_trip_ms", .nan)
        measurements.set("network_round_trip_ms", -.infinity)
        measurements.set("network_round_trip_ms", -1)
        measurements.set("target_bitrate", 12_000_000)
        measurements.add("network_round_trip_ms", .nan)
        measurements.add("network_round_trip_ms", .infinity)
        measurements.add("network_round_trip_ms", -1)
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in measurements.add("presented_frames") }
        let snapshot = measurements.snapshot()
        try require(snapshot["network_round_trip_ms"] == 12.5, "Invalid measured values cannot replace valid telemetry")
        try require(snapshot["presented_frames"] == 1000, "Concurrent frame counters are exact")
        try require(snapshot["session_seconds", default: -1] >= 0, "Session duration uses local uptime")
        let overflow = NativeSessionMeasurements()
        overflow.set("sent_video_bytes", Double.greatestFiniteMagnitude)
        overflow.add("sent_video_bytes", Double.greatestFiniteMagnitude)
        try require(overflow.snapshot()["sent_video_bytes"] == Double.greatestFiniteMagnitude,
                    "Counter overflow cannot corrupt an existing measurement")
        let reportData = try measurements.report()
        let report = try JSONSerialization.jsonObject(with: reportData) as! [String: Any]
        try require(Set(report.keys) == ["schema", "measurements", "notes"] && report["schema"] as? Int == 1,
                    "Diagnostics use the bounded measurement-only schema")
        let values = report["measurements"] as! [String: Double]
        try require(Set(values.keys) == ["network_round_trip_ms", "target_bitrate", "presented_frames", "session_seconds"],
                    "Diagnostics contain only measurements and session duration")
        try require(values.values.allSatisfy { $0.isFinite && $0 >= 0 }, "Diagnostics contain finite nonnegative measurements")
        let reportText = String(decoding: reportData, as: UTF8.self)
        for sensitive in [secret.base64EncodedString(), privateKey.base64EncodedString(), code.address, code.name,
                          "privateKey", "publicKey", "secret", "clipboard", "keyCode", "pairing_code"] {
            try require(!reportText.contains(sensitive), "Diagnostics contain no pairing, endpoint, user input, or clipboard data")
        }
        let notes = report["notes"] as? [String] ?? []
        try require(notes.contains(where: { $0.contains("not click-to-photon") }), "Diagnostics do not mislabel RTT as display latency")

        try NativeTransport.check(Int32(ML_SESSION_OK))
        for status in [ML_SESSION_INVALID, ML_SESSION_IO, ML_SESSION_TIMEOUT, ML_SESSION_AUTH, ML_SESSION_PROTOCOL,
                       ML_SESSION_CLOSED, ML_SESSION_BUFFER, ML_SESSION_BUSY, ML_SESSION_INTERNAL,
                       ML_SESSION_RATE_LIMITED, ML_SESSION_STALLED, ML_SESSION_STORAGE] {
            try rejects("Rust session errors cross the Swift boundary as errors") { try NativeTransport.check(Int32(status)) }
        }
        try require(String(cString: ml_session_error_string(Int32(ML_SESSION_STALLED))).contains("stopped responding"),
                    "Rust supplies readable session errors")
        // Saturating the network writer belongs to the separate loopback stream
        // integration suite. This suite sends no network packets.
    }
}

extension NativeSessionTests {
    /// Tuning, telemetry wrappers, measurement intervals, and the real CLI
    /// against the local socket in a temporary MACLINK_HOME.
    static func testTelemetry() throws {
        let defaults = NativeTuning.defaults
        try require(defaults.bitrate == 25_000_000 && defaults.maxWidth == 3840 && defaults.fps == 60
                    && defaults.inFlight == 2 && defaults.keyframeSeconds == 2, "Rust supplies the tuning defaults")
        var change = MLTuning(); change.fps = 30; change.bitrate_kbps = 12_000
        let merged = defaults.merged(NativeTuning(raw: change))
        try require(merged?.fps == 30 && merged?.bitrate == 12_000_000 && merged?.maxWidth == 3840, "Tuning merges present fields")
        var wide = MLTuning(); wide.max_width = 5120
        try require(defaults.merged(NativeTuning(raw: wide)) == nil, "Out-of-bounds tuning is rejected")
        let stats: NativeStats = [.captureFps: 42, .encodeMs: 23.5, .rttMs: 8]
        guard case .stats(let restored) = try NativeTelemetry(validated: NativeTelemetry.stats(stats).raw), restored == stats else {
            throw Failure("Stats round-trip the C ABI")
        }
        guard case .tuning(let tuning) = try NativeTelemetry(validated: NativeTelemetry.tuning(NativeTuning(raw: change)).raw),
              tuning.fps == 30 else { throw Failure("Tuning round-trips the C ABI") }
        checks += 2

        let measurements = NativeSessionMeasurements()
        _ = measurements.nextInterval()
        for _ in 0..<30 { measurements.add("encoded_frames"); measurements.add("encode_ms_total", 20) }
        measurements.recordMax("encode_ms", 31); measurements.recordMax("encode_ms", 12)
        Thread.sleep(forTimeInterval: 0.5)
        let interval = measurements.nextInterval()
        try require(interval.delta("encoded_frames") == 30 && interval.average("encode_ms_total", per: "encoded_frames") == 20,
                    "Intervals report counter changes and averages")
        try require(abs(interval.rate("encoded_frames") - 30 / interval.seconds) < 0.001 && interval.maxima["encode_ms"] == 31,
                    "Intervals report rates and maxima")
        let next = measurements.nextInterval()
        try require(next.delta("encoded_frames") == 0 && next.maxima.isEmpty, "Each interval starts fresh")

        let arguments = CommandLine.arguments
        guard arguments.count > 1 else { print("Skipping CLI telemetry check: no CLI path given."); return }
        let home = "/tmp/mls-\(getpid())"
        try? FileManager.default.removeItem(atPath: home)
        setenv("MACLINK_HOME", home, 1)
        defer { NativeTelemetryServer.stop(); try? FileManager.default.removeItem(atPath: home) }
        try require(NativeTelemetryServer.start() == 0, "The local telemetry socket starts in MACLINK_HOME")
        func cli(_ command: [String]) throws -> Process {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: arguments[1])
            process.arguments = ["--config-dir", home] + command
            process.standardOutput = output; process.standardError = output
            try process.run()
            return process
        }
        func finish(_ process: Process, publishing: Bool = false) throws -> String {
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                if publishing {
                    NativeTelemetryServer.publish(role: Int(ML_ROLE_VIEWER), seconds: 3, local: [.rttMs: 7.5], peer: [.captureFps: 42],
                                                  peerAge: 0.4, tuning: defaults)
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning { process.terminate(); throw Failure("CLI telemetry command timed out") }
            let output = (process.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile()
            return String(decoding: output, as: UTF8.self)
        }
        let tune = try cli(["tune", "--fps", "24", "--bitrate-mbps", "18"])
        let tuneOutput = try finish(tune)
        try require(tune.terminationStatus == 0 && tuneOutput.contains("queued"), "maclink tune queues a command: \(tuneOutput)")
        let taken = NativeTelemetryServer.takeTuning()
        try require(taken?.fps == 24 && taken?.bitrate == 18_000_000, "The app takes the CLI's tuning")
        let rejected = try cli(["tune", "--fps", "61"])
        _ = try finish(rejected)
        try require(rejected.terminationStatus != 0 && NativeTelemetryServer.takeTuning() == nil, "Out-of-bounds CLI tuning is refused")
        let stream = try cli(["telemetry", "--count", "2"])
        let streamOutput = try finish(stream, publishing: true)
        let lines = streamOutput.split(separator: "\n")
        try require(stream.terminationStatus == 0 && lines.count == 2 && lines[0].contains("\"rtt_ms\":7.5")
                    && lines[0].contains("\"capture_fps\":42") && lines[0].contains("\"role\":\"viewer\""),
                    "maclink telemetry streams snapshots: \(streamOutput)")
    }
}

/// Encodes a dictionary the way the earlier Swift build stored credentials.
private struct LegacyCredential: Encodable {
    let object: [String: Any]
    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for (key, value) in object {
            if let number = value as? Int { try container.encode(number, forKey: Key(stringValue: key)) }
            else if let text = value as? String { try container.encode(text, forKey: Key(stringValue: key)) }
        }
    }
}

extension NativeSessionTests {
    /// The pasteboard side of the shared clipboard, on a private named pasteboard.
    static func testClipboard() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.maclink.tests.\(getpid())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        try require(NativePasteboard.read(board) == nil, "An empty pasteboard shares nothing")
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
            board.clearContents()
            board.setString("not for sharing", forType: .string)
            board.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
            try require(NativePasteboard.read(board) == nil, "Items marked \(marker) are never shared")
        }

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])
        let content = NativeClipboardContent(text: "héllo ✓", rtf: Data("{\\rtf1 hi}".utf8), png: png)
        NativePasteboard.write(content, to: board)
        let read = NativePasteboard.read(board)
        try require(read?.content == content && read?.tiff == nil, "Text, rich text and PNG round-trip a pasteboard")
        try require(content.isValid && content.summary.hasPrefix("text, rich text, image"), "Rust accepts it; the log names kinds only")

        let limit = NativeClipboardContent.maxBytes
        let largest = String(repeating: "a", count: limit)
        try require(NativeClipboardContent(text: largest + "a").fitted() == nil, "Text over 4 MiB is not shared")
        let full = NativeClipboardContent(text: largest, png: png).fitted()
        try require(full?.text == largest && full?.png == nil && full?.isValid == true, "Text is kept; an image that no longer fits is dropped")
        try require(NativeClipboardContent(text: "", png: png).fitted() == NativeClipboardContent(png: png), "Empty text is omitted")
        try require(!NativeClipboardContent(text: "x", rtf: Data("plain".utf8)).isValid, "Rust rejects rich text without its signature")
        try require(!NativeClipboardContent(png: Data("GIF89a".utf8)).isValid, "Rust rejects an image that is not PNG")
        let mixed = NativeClipboardContent(text: "keep", rtf: Data("\u{FEFF}{\\rtf1 x}".utf8), png: Data("GIF89a".utf8)).fitted()
        try require(mixed == NativeClipboardContent(text: "keep"), "Representations Rust would reject are dropped, never sent")
        try require(NativeClipboardContent(text: "code: MLP1.eyJhIjoxfQ==").fitted() == nil, "MacLink pairing codes are never shared")
        board.clearContents(); board.setString("MLP1.eyJhIjoxfQ==", forType: .string)
        try require(NativePasteboard.read(board) == nil, "A pairing code without its concealed marker is still not shared")
        NativePasteboard.write(content, to: board)

        var sent: [NativeClipboardContent] = []
        let sync = NativeClipboardSync(pasteboard: board)
        sync.onSend = { sent.append($0) }
        // Pasteboard work runs on the sync's own queue; sends arrive on main.
        func settle() {
            sync.waitUntilIdle()
            let until = ProcessInfo.processInfo.systemUptime + 0.1
            while ProcessInfo.processInfo.systemUptime < until { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        }
        sync.start(includeCurrent: true); settle()
        try require(sent == [content], "A new viewer session shares what is already copied")
        sync.poll(); settle()
        try require(sent.count == 1, "Nothing new, nothing sent")
        let remote = NativeClipboardContent(text: "from the other Mac")
        sync.apply(remote); sync.poll(); settle()
        try require(sent.count == 1 && NativePasteboard.read(board)?.content == remote, "The other Mac's copy is applied and never echoed back")
        NativePasteboard.write(remote, to: board); sync.poll(); settle()
        try require(sent.count == 1, "The same item returning through another path, such as a clipboard manager, is not sent back")
        board.clearContents(); board.setString("via Universal Clipboard", forType: .string)
        board.setData(Data(), forType: NativePasteboard.remoteClipboardType); sync.poll(); settle()
        try require(sent.count == 1, "Items Universal Clipboard brought from another device are not sent")
        sync.start(includeCurrent: true); settle()
        try require(sent.count == 1, "A reconnect does not resend what was last exchanged")
        board.clearContents(); board.setString("copied again", forType: .string)
        sync.poll(); settle()
        try require(sent.count == 2 && sent.last?.text == "copied again", "A new copy is sent")
        board.clearContents(); board.setString("copied again", forType: .string)
        sync.poll(); settle()
        try require(sent.count == 2, "Copying the item just sent again sends nothing")

        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let tiff = image?.tiffRepresentation else { throw Failure("Synthetic TIFF") }
        board.clearContents(); board.setData(tiff, forType: .tiff)
        sync.poll(); settle()
        try require(sent.count == 3 && sent.last?.png?.starts(with: png.prefix(8)) == true && sent.last?.isValid == true,
                    "A TIFF image is shared as PNG, converted off the main thread")
        for _ in 0..<50 { sync.poll() }
        settle()
        try require(sent.count == 3, "Polls waiting behind a read coalesce and send nothing new")

        board.clearContents(); board.writeObjects([NSURL(fileURLWithPath: "/tmp/example.txt")])
        if let files = NativePasteboard.read(board) {
            try require(files.content.png == nil && files.content.rtf == nil && files.tiff == nil, "Copied files share names only")
        } else { checks += 1 }
    }
}
