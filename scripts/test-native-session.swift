// Swift session-boundary checks. Pairing, address, control and peer-store rules
// are Rust's (cargo test -p maclink-session); these cover the Swift wrappers.
// No Keychain access, accepted peer, packet traffic, live capture, input
// injection, or permission request. A loopback-only ephemeral listener is closed
// immediately to test channel queue state safely; peers use a temporary folder.
// Built and run by scripts/test-native.sh, which links the arm64 Rust static library.
import Foundation
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
    static func main() {
        do {
            try run()
            print("Native session tests passed: \(checks) checks; Rust pairing, peer store, control and display boundaries, cancellation, bounded delivery, and diagnostics. Loopback listener only; no packets, Keychain, capture, or input access.")
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
        let code = try NativePairingCode.forHost(address: "Studio.local", computerName: " Studio\u{200D} Mac\n", identity: identity)
        try require(code.address == "studio.local" && code.name == "Studio Mac", "Rust normalizes this Mac's address and name")
        try require(code.publicKey == publicKey && code.secret == secret, "Pairing code carries exact credentials")
        try require(code.peerID.count == 64 && code.peerID.allSatisfy { "0123456789abcdef".contains($0) },
                    "Peer ID is a fixed lowercase public-key fingerprint")
        let encoded = try code.encoded()
        let decoded = try NativePairingCode.parse(" \n\t" + encoded + "\r\n ")
        try require(decoded.address == code.address && decoded.name == code.name && decoded.peerID == code.peerID
                     && decoded.secret == secret, "Pairing text round-trips through Rust")
        let restored = try NativePairingCode.fromCredential(code.credential())
        try require(restored.peerID == code.peerID && restored.secret == secret, "Keychain credentials round-trip through Rust")
        let legacyObject: [String: Any] = ["version": 1, "address": "studio.local", "name": "Studio Mac",
                                           "publicKey": publicKey.base64EncodedString(), "secret": secret.base64EncodedString()]
        let legacy = try NativePairingCode.fromCredential(JSONEncoder().encode(LegacyCredential(object: legacyObject)))
        try require(legacy.peerID == code.peerID, "Credentials saved by the earlier Swift encoder remain readable")
        for malformed in ["", "MLP1.not base64!", String(encoded.dropFirst(5)), "MLP2." + String(encoded.dropFirst(5))] {
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
                                              .ping(0), .pong(UInt64.max), .keyframe] {
            try require(try NativeControlMessage(validated: message.raw) == message, "Every control message round-trips the C ABI")
        }
        var unknown = MLControlMessage(); unknown.kind = 9
        try rejects("Unknown control kinds are rejected") { _ = try NativeControlMessage(validated: unknown) }

        let token = NativeRunToken()
        try require(token.isActive, "Run token begins active")
        let winners = Counter()
        DispatchQueue.concurrentPerform(iterations: 128) { _ in if token.cancel() { winners.increment() } }
        try require(winners.value == 1 && !token.isActive, "Exactly one concurrent cancellation wins")
        try require(!token.cancel() && !token.isActive, "Cancellation is permanent and idempotent")

        // A closed local listener gives us a transport wrapper without opening a
        // remote session. Main-queue admission does not use the underlying I/O.
        let closedTransport = try NativeTransport.listen(identity: generated, bindAddress: "127.0.0.1", port: 0)
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
