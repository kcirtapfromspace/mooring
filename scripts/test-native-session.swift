// Swift session-boundary checks. Pairing, address, control and peer-store rules
// are Rust's (cargo test -p mooring-session); these cover the Swift wrappers.
// No Keychain access, live capture, input injection, or permission request.
// Pairing runs over a loopback-only ephemeral listener with a temporary device
// list; another is closed immediately to test channel queue state safely;
// peers use a temporary folder.
// Clipboard checks use a private, uniquely named pasteboard, never the user's.
// Pointer checks draw a synthetic image; they never read the system pointer.
// Built and run by scripts/test-native.sh, which links the arm64 Rust static library.
import AppKit
import Security
import CoreGraphics
import IOKit.pwr_mgt

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
    static func connectOnce(_ listener: NativeTransport, _ code: NativePairingCode, _ key: NativeDeviceKey,
                            addresses: [String] = ["127.0.0.1"])
        -> (Result<(NativeTransport, NativeTransport.Mode, String), Error>, NativeTransport?) {
        let host = Slot<NativeTransport>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { host.value = try? listener.accept(); done.signal() }
        let viewer = Result { try NativeTransport.connect(addresses: addresses, code: code, deviceKey: key,
                                                          deviceName: "MacBook Pro", port: listener.listeningPort) }
        done.wait()
        return (viewer, host.value)
    }
    /// The next message within about two seconds.
    static func next(_ transport: NativeTransport) throws -> NativeSessionMessage {
        for _ in 0..<40 { if let message = try transport.receive() { return message } }
        throw Failure("No message arrived")
    }
    static func refused(_ result: Result<(NativeTransport, NativeTransport.Mode, String), Error>) -> Bool {
        if case .failure(let error) = result { return (error as? NativeSessionError)?.isAuthenticationFailure == true }
        return false
    }
    /// A one-time code approves this Mac's key, the saved pairing connects by
    /// it, and a removed Mac is refused. Loopback and a temporary list only.
    static func testDevicePairing() throws {
        // Protocol 5 with what every build announces, plus the wait of
        // previews 22 to 28, so the viewer may say it's leaving as it does to
        // such a host.
        ml_capabilities_set(NativeCapabilities.local(hevc444: false, virtualDisplay: false, audio: false) | UInt64(ML_CAPABILITY_WAITS))
        defer { ml_capabilities_set(0) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mooring-devices-\(UUID().uuidString)")
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

        // Nothing listens on ::1, so the second address connects.
        let (paired, host) = connectOnce(listener, code, key, addresses: ["::1", "127.0.0.1"])
        let (viewer, mode, used) = try paired.get()
        let id = host?.peerDevice ?? ""
        try require(mode == .pair && mode.approvedKey && id.count == 64, "A one-time code approves this Mac's key")
        try require(used == "127.0.0.1", "The address that connected is reported")
        let approved = try devices.load()
        try require(approved.devices.map(\.id) == [id] && approved.devices.first?.name == "MacBook Pro"
                    && approved.devices.first?.migrated == false && !approved.legacy.accepted,
                    "The sharing Mac lists the approved Mac by name")
        viewer.close(); host?.close()
        let (reused, reusedHost) = connectOnce(listener, code, try NativeDeviceKey.create())
        try require(refused(reused) && reusedHost == nil && (try devices.load().devices.count) == 1, "A used code is refused")

        let saved = try code.device()
        let (returning, returningHost) = connectOnce(listener, saved, key)
        let (again, againMode, _) = try returning.get()
        try require(againMode == .device && !againMode.approvedKey && returningHost?.peerDevice == id,
                    "The saved pairing connects as the approved Mac")
        guard let returningHost else { throw Failure("The host session is missing") }
        // A viewer that ends the session on purpose says so after anything queued, then closes.
        guard case .control(.hello) = try next(again), case .control(.hello) = try next(returningHost) else {
            throw Failure("Protocol 5 sessions open with each side's Hello")
        }
        let writer = DispatchQueue(label: "dev.mooring.tests.blocked-writer")
        let writerEntered = DispatchSemaphore(value: 0), writerUnblock = DispatchSemaphore(value: 0)
        writer.async { writerEntered.signal(); writerUnblock.wait() }
        try require(writerEntered.wait(timeout: .now() + 2) == .success, "Writer is blocked before the clipboard packet")
        let channel = NativeSessionChannel(again, writer: writer), copyScope = NativeRunToken(), copyCompletions = Counter()
        channel.send(.clipboard(NativeClipboardContent(text: "retired clipboard")), whileActive: copyScope) { copyCompletions.increment() }
        copyScope.cancel()
        channel.control(.ping(7))
        channel.close(after: .control(.leaving))
        writerUnblock.signal()
        let ping = try next(returningHost), leaving = try next(returningHost)
        var closed = false
        do { _ = try next(returningHost) } catch { closed = (error as? NativeSessionError)?.status == Int32(ML_SESSION_CLOSED) }
        var ordered = false
        if case .control(.ping(7)) = ping, case .control(.leaving) = leaving { ordered = true }
        try require(ordered && closed && copyCompletions.value == 1,
                    "A clipboard retired on the writer is skipped while ordinary ordered controls and completions remain intact")
        returningHost.close()
        try require(returningHost.peerDevice == nil, "A closed session names no Mac")

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
    /// Authenticate, revoke only that viewer, restart the listener, require a
    /// new code, and leave another approved key untouched. Loopback only.
    static func testAsymmetricRevocation() throws {
        ml_capabilities_set(NativeCapabilities.local(hevc444: false, virtualDisplay: false, audio: false))
        defer { ml_capabilities_set(0) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mooring-revoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let devices = NativeDeviceStore(directory: folder.path)
        try devices.prepare(acceptOldCode: false)
        let identity = try NativeHostIdentity.create()
        var listener = try NativeTransport.listen(identity: identity, devices: devices, bindAddress: "127.0.0.1", port: 0)
        defer { listener.close() }
        func pair(_ key: NativeDeviceKey) throws -> (NativePairingCode, NativeTransport, NativeTransport) {
            let code = try NativePairingCode.forHost(address: "127.0.0.1", computerName: "Demo", identity: identity,
                                                    oneTimeSecret: listener.newPairingSecret())
            let (result, host) = connectOnce(listener, code, key)
            let (viewer, _, _) = try result.get()
            guard let host else { throw Failure("No host") }
            guard case .control(.hello) = try next(viewer), case .control(.hello) = try next(host) else { throw Failure("No Hello") }
            return (try code.device(), viewer, host)
        }
        let otherKey = try NativeDeviceKey.create(), revokedKey = try NativeDeviceKey.create()
        let (otherCode, otherViewer, otherHost) = try pair(otherKey)
        let otherID = otherHost.peerDevice!
        otherViewer.close(); otherHost.close()
        let (revokedCode, viewer, host) = try pair(revokedKey)
        try viewer.send(.control(.revokePairing))
        guard case .control(.revokePairing) = try next(host) else { throw Failure("No revocation") }
        try require(try devices.load().devices.map(\.id) == [otherID], "Viewer revokes only its own authenticated key")
        viewer.close(); host.close(); listener.close()
        listener = try NativeTransport.listen(identity: identity, devices: devices, bindAddress: "127.0.0.1", port: 0)
        let (removed, removedHost) = connectOnce(listener, revokedCode, revokedKey)
        try require(refused(removed) && removedHost == nil, "Revocation persists across listener restart")
        let (kept, keptHost) = connectOnce(listener, otherCode, otherKey)
        let (keptViewer, _, _) = try kept.get(); keptViewer.close(); keptHost?.close()
        let (_, repairedViewer, repairedHost) = try pair(try NativeDeviceKey.create())
        try repairedHost.send(.control(.revokePairing))
        guard case .control(.revokePairing) = try next(repairedViewer) else { throw Failure("No host revocation notice") }
        repairedViewer.close(); repairedHost.close()
    }

    /// Exercise the owner-ACL failure without reading/writing any real Keychain.
    static func testKeychainErasure() throws {
        var values: [String: Data] = [:]
        var deleteStatus = errSecInvalidOwnerEdit
        var updateStatus = errSecSuccess
        var keychain = NativeKeychain()
        keychain.copyItem = { query, out in
            let query = query as! [String: Any]
            guard let account = query[kSecAttrAccount as String] as? String, let value = values[account] else { return errSecItemNotFound }
            out?.pointee = value as CFData
            return errSecSuccess
        }
        keychain.updateItem = { query, updates in
            let query = query as! [String: Any], updates = updates as! [String: Any]
            precondition(updates.count == 1 && updates[kSecValueData as String] != nil, "Existing items never edit owner/access attributes")
            if updateStatus != errSecSuccess { return updateStatus }
            let account = query[kSecAttrAccount as String] as! String
            guard values[account] != nil else { return errSecItemNotFound }
            values[account] = updates[kSecValueData as String] as? Data
            return errSecSuccess
        }
        keychain.addItem = { query, _ in
            let query = query as! [String: Any]
            values[query[kSecAttrAccount as String] as! String] = query[kSecValueData as String] as? Data
            return errSecSuccess
        }
        keychain.deleteItem = { query in
            if deleteStatus == errSecSuccess { values.removeValue(forKey: (query as! [String: Any])[kSecAttrAccount as String] as! String) }
            return deleteStatus
        }
        let identity = try NativeHostIdentity.create()
        let code = try NativePairingCode.forHost(address: "demo.local", computerName: "Demo", identity: identity, oneTimeSecret: Data(repeating: 7, count: 32)).device()
        let key = try NativeDeviceKey.create()
        try keychain.savePeerCode(code, deviceKey: key)
        try require(try keychain.peerDeviceKey(code.peerID).privateKey == key.privateKey, "A per-peer key survives Keychain encoding")
        try keychain.deletePeerCode(code.peerID)
        try require(values["peer-" + code.peerID]?.isEmpty == true && (try keychain.peerCode(code.peerID)) == nil,
                    "An ownership delete failure erases both credential and private key")
        try keychain.savePeerCode(code, deviceKey: key)
        updateStatus = errSecInvalidOwnerEdit
        try rejects("Failed erasure must report failure") { try keychain.deletePeerCode(code.peerID) }
        try require(try keychain.peerCode(code.peerID)?.peerID == code.peerID, "An unerasable credential is kept for retry")
        updateStatus = errSecSuccess; deleteStatus = errSecSuccess
        try keychain.deletePeerCode(code.peerID)
        deleteStatus = errSecItemNotFound
        try keychain.deletePeerCode(code.peerID)
        // Earlier credentials still use the existing device key, preserving pairings.
        let legacyKey = try keychain.deviceKey()
        try keychain.savePeerCode(code)
        try require(try keychain.peerDeviceKey(code.peerID).privateKey == legacyKey.privateKey, "Earlier pairings retain their key")
    }

    /// The sharing Mac's pointer as sent and as the viewer rebuilds it: a
    /// 2-point square drawn 3 points right of and 5 points below the top-left
    /// corner must stay there at 2x, including for a size in fractional points.
    static func testPointer() throws {
        func opaqueBox(_ rep: NSBitmapImageRep) -> (Int, Int, Int, Int) {
            var box = (Int.max, Int.max, -1, -1)
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                box = (min(box.0, x), min(box.1, y), max(box.2, x), max(box.3, y))
            } }
            return box
        }
        for size in [NSSize(width: 12, height: 20), NSSize(width: 11.5, height: 19.5)] {
            let image = NSImage(size: size, flipped: true) { _ in NSColor.black.setFill(); NSRect(x: 3, y: 5, width: 2, height: 2).fill(); return true }
            guard let rep = NativeCursorWatcher.render(image), let png = rep.representation(using: .png, properties: [:]) else {
                throw Failure("The pointer did not render")
            }
            try require(rep.pixelsWide == 24 && rep.pixelsHigh == 40 && rep.size == NSSize(width: 12, height: 20),
                        "A pointer renders at 2x, its size in points rounded up")
            try require(opaqueBox(rep) == (6, 10, 9, 13), "The pointer is drawn full size from the top left, where its hotspot is measured")
            let pointer = NativeCursorImage(width: 12, height: 20, hotspotX: 3, hotspotY: 5, png: png)
            guard let cursor = pointer.cursor, let shown = NativeCursorWatcher.render(cursor.image) else { throw Failure("The viewer did not rebuild the pointer") }
            try require(cursor.hotSpot == NSPoint(x: 3, y: 5) && opaqueBox(shown) == (6, 10, 9, 13),
                        "The viewer draws the shape at its hotspot, where clicks land")
        }
    }
    /// Clock placement and latency arithmetic; no session or display.
    static func testLatency() throws {
        // Every build announces what it always supports; self-tests add the rest.
        let always = UInt64(ML_CAPABILITY_CURSOR) | UInt64(ML_CAPABILITY_GESTURES) | UInt64(ML_CAPABILITY_LATENCY)
            | UInt64(ML_CAPABILITY_VERSION) | UInt64(ML_CAPABILITY_PAIRING_REVOCATION)
        try require(NativeCapabilities.local(hevc444: false, virtualDisplay: false, audio: false) == always,
                    "Pointer shapes, gestures, latency and versions are always announced; the 12-hour wait no longer is")
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
        let hostile = NativeClockSync()
        hostile.add(sentUs: 1, receivedUs: 1, hostUs: 0)
        try require(hostile.latency(NativeFrameTiming(hostUs: UInt64(Int64.max), decodeStartUs: 103, decodedUs: 104, presentedUs: 105)) == nil,
                    "An extreme capture timestamp cannot overflow a negative offset")
        hostile.reset(); hostile.add(sentUs: 0, receivedUs: 0, hostUs: UInt64(Int64.max))
        try require(hostile.latency(NativeFrameTiming(hostUs: 0, decodeStartUs: UInt64(Int64.max), decodedUs: UInt64(Int64.max),
                                                     presentedUs: UInt64(Int64.max))) == nil,
                    "Subtracting a far-behind capture cannot overflow a stage timestamp")
        try require(hostile.latency(NativeFrameTiming(hostUs: UInt64.max, decodeStartUs: 1, decodedUs: 2, presentedUs: 3)) == nil,
                    "Unsigned timestamps outside the signed range are discarded")
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
        // The link meter: 125 kB sent over about 100 ms while 200 kB waited is about 10 Mbit/s.
        func backlog(_ sent: UInt64) -> MLSendQueue {
            MLSendQueue(queued_bytes: 200_000, round_trip_ms: 20, sent_bytes: sent, retransmitted_bytes: 0)
        }
        flow.sample(backlog(0)); Thread.sleep(forTimeInterval: 0.1); flow.sample(backlog(125_000))
        let link = flow.takeLinkKbps()
        try require((7_000...10_500).contains(link), "The link meter reports kbit/s in real time: \(link)")
        try require(flow.takeLinkKbps() == 0, "Each second's link rate starts again")
        flow.sample(backlog(0)); flow.reset(); flow.sample(backlog(500_000)); Thread.sleep(forTimeInterval: 0.05)
        try require(flow.takeLinkKbps() == 0, "A new session forgets the last one's readings")
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
            print("Native session tests passed: \(checks) checks; Rust pairing, per-Mac keys over loopback, peer store, control and display boundaries, the pointer image, cancellation, bounded delivery, diagnostics and the shared clipboard. Loopback only; no Keychain, capture, or input access.")
        } catch {
            fputs("Native session tests failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    static func run() throws {
        try testViewerDiagnostics()
        try testViewerMeasurementStream()
        let publicKey = Data((0..<32).map { UInt8($0 + 1) })
        let secret = Data((0..<32).map { UInt8($0 + 101) })
        let privateKey = Data((0..<32).map { UInt8($0 + 201) })
        let identity = NativeHostIdentity(privateKey: privateKey, publicKey: publicKey, secret: secret)
        let code = try NativePairingCode.forHost(address: "Studio.local", computerName: " Studio\u{200D} Mac\n", identity: identity,
                                                 oneTimeSecret: secret, alternates: ["192.168.25.201", "studio.local", "no//t"])
        try require(code.alternates == ["192.168.25.201"] && code.addresses == ["studio.local", "192.168.25.201"],
                    "A code lists this Mac's other addresses, leaving out repeats and invalid ones")
        for address in NativePairingCode.localAddresses() {
            try require(NativePairingCode.normalizedAddress(address) == address, "This Mac's own addresses follow the host rule")
        }
        try require(code.address == "studio.local" && code.name == "Studio Mac", "Rust normalizes this Mac's address and name")
        try require(code.publicKey == publicKey && code.secret == secret && code.kind == .oneTime, "Pairing code carries exact credentials")
        try require(code.peerID.count == 64 && code.peerID.allSatisfy { "0123456789abcdef".contains($0) },
                    "Peer ID is a fixed lowercase public-key fingerprint")
        let encoded = try code.encoded()
        let decoded = try NativePairingCode.parse(" \n\t" + encoded + "\r\n ")
        try require(encoded.hasPrefix("MLP2.") && decoded.address == code.address && decoded.name == code.name
                     && decoded.peerID == code.peerID && decoded.secret == secret && decoded.kind == .oneTime && decoded.alternates == code.alternates,
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

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mooring-peers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = NativePeerStore(directory: folder.path)
        try require(try store.load().isEmpty, "A missing peer store is empty")
        let legacyPeers = try JSONSerialization.data(withJSONObject: [["id": String(repeating: "a", count: 64), "name": "Old Mac", "address": "old.local"]])
        try store.importLegacy(legacyPeers)
        let peer = try store.remember(code, tried: ["Studio.Local"])
        try require(peer.id == code.peerID && peer.addresses == ["studio.local", "192.168.25.201"],
                    "Remembered peers use the Rust ID and address rule, and keep the code's other addresses")
        try require(try store.load().map(\.name) == ["Studio Mac", "Old Mac"], "Most recent peer first after legacy import")
        try store.connected(peer.id, through: "192.168.25.201")
        try require(try store.load().first?.addresses == ["192.168.25.201", "studio.local"], "The address that worked goes first")
        try rejects("Invalid addresses are not saved") { _ = try store.remember(code, tried: ["http://studio.local"]) }
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
                                              .updateStatus(.ready, ready: NativeVersion(build: 25, release: 3 << 32 | 20)),
                                              .leaving, .revokePairing] {
            try require(try NativeControlMessage(validated: message.raw) == message, "Every control message round-trips the C ABI")
        }
        try testLatency()
        try testCapabilityGate()
        try testWakeRecovery()
        try testPointer()
        var unknown = MLControlMessage(); unknown.kind = 14
        try rejects("Unknown control kinds are rejected") { _ = try NativeControlMessage(validated: unknown) }

        try testTelemetry()
        try testClipboard()
        try testDevicePairing()
        try testAsymmetricRevocation()
        try testKeychainErasure()

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
    /// against the local socket in a temporary MOORING_HOME.
    static func testTelemetry() throws {
        let defaults = NativeTuning.defaults
        try require(defaults.bitrate == 25_000_000 && defaults.maxWidth == 3840 && defaults.fps == 60
                    && defaults.inFlight == 2 && defaults.keyframeSeconds == 0, "Rust supplies the tuning defaults")
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
        setenv("MOORING_HOME", home, 1)
        defer { NativeTelemetryServer.stop(); try? FileManager.default.removeItem(atPath: home) }
        try require(NativeTelemetryServer.start() == 0, "The local telemetry socket starts in MOORING_HOME")
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
        try require(tune.terminationStatus == 0 && tuneOutput.contains("queued"), "mooring tune queues a command: \(tuneOutput)")
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
                    "mooring telemetry streams snapshots: \(streamOutput)")
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
        let board = NSPasteboard(name: NSPasteboard.Name("dev.mooring.tests.\(getpid())"))
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
        try require(read?.content.text == content.text && read?.content.png == content.png && read?.tiff == nil
                    && read?.content.rtf.flatMap { NativePasteboard.shareableRTF($0) } != nil,
                    "Text and PNG round-trip; rich text is inspected and reserialized")
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
        try require(NativeClipboardContent(text: "code: MLP1.eyJhIjoxfQ==").fitted() == nil, "Mooring pairing codes are never shared")
        board.clearContents(); board.setString("MLP1.eyJhIjoxfQ==", forType: .string)
        try require(NativePasteboard.read(board) == nil, "A pairing code without its concealed marker is still not shared")
        let identity = NativeHostIdentity(privateKey: Data(repeating: 1, count: 32), publicKey: Data(repeating: 2, count: 32),
                                          secret: Data(repeating: 3, count: 32))
        let generated = try NativePairingCode.forHost(address: "test.local", computerName: "Test", identity: identity,
                                                      oneTimeSecret: Data(repeating: 4, count: 32))
        var legacyRaw = generated.raw; legacyRaw.kind = NativePairingCode.Kind.legacy.rawValue
        for candidate in [NativePairingCode(raw: legacyRaw), generated] {
            let code = try candidate.encoded()
            try require(NativeClipboardContent(text: "before \(code) after").fitted() == nil, "Every generated pairing code is private")
            NativePasteboard.write(NativeClipboardContent(text: code), to: board)
            try require(NativePasteboard.read(board) == nil, "Marker-free generated codes cannot enter sync")
        }
        let code = try NativePairingCode.forHost(address: "test.local", computerName: "Test", identity: identity,
                                                 oneTimeSecret: Data(repeating: 4, count: 32)).encoded()
        let payload = code.dropFirst(5)
        for encoded in ["{\\rtf1\\ansi \(code)}", "{\\rtf1\\ansi M{\\b L}P2.\(payload)}",
                        "{\\rtf1\\ansi \\'4d\\'4c\\'50\\'32.\(payload)}",
                        "{\\rtf1\\ansi\\uc1 \\u77?\\u76?\\u80?\\u50?.\(payload)}",
                        "{\\rtf1{\\info{\\comment \(code)}}ordinary}"] {
            let rtf = Data(encoded.utf8)
            try require(NativeClipboardContent(rtf: rtf).fitted() == nil, "RTF-only pairing material is private, including escaped or grouped prefixes")
            try require(NativeClipboardContent(text: "ordinary", rtf: rtf).fitted() == nil, "Benign plain text cannot mask a rich-text secret")
            NativePasteboard.write(NativeClipboardContent(rtf: rtf), to: board)
            try require(NativePasteboard.read(board) == nil, "The pasteboard rejects secret-bearing RTF before sync")
        }
        let metadata = Data("{\\rtf1{\\info{\\comment \\'4d\\'4c\\'50\\'32.\(payload)}}ordinary}".utf8)
        let cleaned = NativeClipboardContent(rtf: metadata).fitted()?.rtf
        try require(cleaned != nil && !(String(data: cleaned!, encoding: .utf8) ?? "").contains(String(payload)),
                    "Escaped secrets in non-visible RTF metadata are stripped instead of forwarded")
        let ordinaryRich = NSAttributedString(string: "ordinary rich text", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 15)!])
        let ordinaryRTF = try ordinaryRich.data(from: NSRange(location: 0, length: ordinaryRich.length),
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let fittedRTF = NativeClipboardContent(rtf: ordinaryRTF).fitted()!.rtf!
        let decodedRich = try NSAttributedString(data: fittedRTF, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        try require(decodedRich.string == ordinaryRich.string && decodedRich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                    == ordinaryRich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                    "Ordinary rich-text content and font formatting remain intact")
        NativePasteboard.write(content, to: board)

        var sent: [NativeClipboardContent] = []
        let sync = NativeClipboardSync(pasteboard: board)
        sync.onSend = { content, _ in sent.append(content) }
        // Pasteboard work runs on the sync's own queue; sends arrive on main.
        func settle() {
            sync.waitUntilIdle()
            let until = ProcessInfo.processInfo.systemUptime + 0.1
            while ProcessInfo.processInfo.systemUptime < until { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        }
        sync.start(includeCurrent: true); settle()
        try require(sent == [content.fitted()!], "A new viewer session shares the inspected representations already copied")
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

        NativePasteboard.write(NativeClipboardContent(rtf: ordinaryRTF), to: board)
        sync.poll(); settle()
        try require(sent.count == 4 && sent.last?.rtf == fittedRTF, "An ordinary RTF-only copy is delivered")
        NativePasteboard.write(NativeClipboardContent(rtf: fittedRTF), to: board)
        sync.poll(); settle()
        try require(sent.count == 4, "Normalizing an RTF-only copy does not change its identity or create an echo")
        sync.apply(NativeClipboardContent(rtf: ordinaryRTF)); settle(); sync.poll(); settle()
        try require(sent.count == 4, "An incoming RTF-only copy retains echo suppression")

        board.clearContents(); board.writeObjects([NSURL(fileURLWithPath: "/tmp/example.txt")])
        if let files = NativePasteboard.read(board) {
            try require(files.content.png == nil && files.content.rtf == nil && files.tiff == nil, "Copied files share names only")
        } else { checks += 1 }
        try testClipboardCancellation(board)
    }

    static func testClipboardCancellation(_ board: NSPasteboard) throws {
        var original: [NativeClipboardContent] = [], replacement: [NativeClipboardContent] = []
        let queue = DispatchQueue(label: "dev.mooring.tests.clipboard-cancellation")
        let sync = NativeClipboardSync(pasteboard: board, queue: queue)
        sync.onSend = { content, _ in original.append(content) }
        NativePasteboard.write(NativeClipboardContent(text: "original local copy"), to: board)
        sync.start(includeCurrent: false); sync.waitUntilIdle()
        let entered = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0)
        queue.async { entered.signal(); unblock.wait() }
        try require(entered.wait(timeout: .now() + 2) == .success, "Clipboard queue blocked for a delayed write")
        sync.apply(NativeClipboardContent(text: "stale remote copy")); sync.poll()
        sync.stop(); sync.onSend = { content, _ in replacement.append(content) }; sync.start(includeCurrent: false)
        unblock.signal(); sync.waitUntilIdle(); drainMainQueue()
        try require(board.string(forType: .string) == "original local copy" && original.isEmpty && replacement.isEmpty,
                    "Disable/re-enable invalidates queued reads and writes")

        let source = NativeRunToken(), enteredSource = DispatchSemaphore(value: 0), unblockSource = DispatchSemaphore(value: 0)
        queue.async { enteredSource.signal(); unblockSource.wait() }
        try require(enteredSource.wait(timeout: .now() + 2) == .success, "Clipboard queue blocked for source disconnect")
        sync.apply(NativeClipboardContent(text: "disconnected source"), from: source)
        source.cancel(); unblockSource.signal(); sync.waitUntilIdle()
        try require(board.string(forType: .string) == "original local copy", "A disconnected source cannot write queued content")

        let receivedScope = sync.scopeToken!
        DispatchQueue.main.async { sync.apply(NativeClipboardContent(text: "stale incoming main callback"), within: receivedScope) }
        sync.stop(); sync.start(includeCurrent: false)
        drainMainQueue(); sync.waitUntilIdle()
        try require(board.string(forType: .string) == "original local copy",
                    "Incoming work admitted before disable/re-enable cannot adopt the replacement clipboard scope")

        NativePasteboard.write(NativeClipboardContent(text: "pending old callback"), to: board)
        sync.start(includeCurrent: true); sync.waitUntilIdle() // callback is queued on main but not run
        sync.stop(); NativePasteboard.write(NativeClipboardContent(text: "new session copy"), to: board)
        sync.start(includeCurrent: true); sync.waitUntilIdle(); drainMainQueue(); sync.waitUntilIdle()
        try require(replacement.map { $0.text } == ["new session copy"], "A pending main callback is not revived by a replacement session")

        let readEntered = DispatchSemaphore(value: 0), readUnblock = DispatchSemaphore(value: 0)
        let slow = NativeClipboardSync(pasteboard: board, read: { pasteboard in
            let copy = NativePasteboard.read(pasteboard)
            readEntered.signal(); readUnblock.wait(); return copy
        })
        slow.onSend = { content, _ in original.append(content) }
        slow.start(includeCurrent: true)
        try require(readEntered.wait(timeout: .now() + 2) == .success, "A lazy clipboard read is in progress")
        slow.stop() // must not wait for the blocked read
        slow.onSend = { content, _ in replacement.append(content) }; slow.start(includeCurrent: false)
        readUnblock.signal(); slow.waitUntilIdle(); drainMainQueue()
        try require(original.isEmpty && replacement.count == 1, "A read completed after cancellation cannot leak to any recipient")
        slow.stop(); sync.stop()
    }

    static func testCapabilityGate() throws {
        let gate = NativeCapabilityGate(), canceled = NativeRunToken(), replacement = NativeRunToken()
        var effects: [String] = []
        try require(gate.admit(token: canceled, { effects.append("canceled Keychain/transport/viewer work") }) == .waiting,
                    "The original registered attempt waits for startup probes")
        canceled.cancel()
        try require(gate.admit(token: replacement, { effects.append("replacement") }) == .waiting,
                    "A replacement waits with a new identity")
        gate.complete(); gate.complete()
        try require(effects == ["replacement"], "Closing the original attempt suppresses all deferred side effects; completion runs once")
        try require(gate.admit(token: replacement, {}) == .ready, "Ordinary connections proceed once probes complete")
        try require(gate.admit(token: canceled, {}) == .rejected, "A canceled attempt cannot be revived after readiness")

        let stopped = NativeCapabilityGate(), pending = NativeRunToken()
        _ = stopped.admit(token: pending, { effects.append("after stop") })
        stopped.stop(); stopped.complete()
        try require(!pending.isActive && effects == ["replacement"] && stopped.admit({}) == .rejected,
                    "Stop cancels pending requests and prevents late startup callbacks")

        let bounded = NativeCapabilityGate()
        var calls = 0
        for index in 0..<12 {
            let admission = bounded.admit { calls += 1 }
            try require(admission == (index < 8 ? .waiting : .rejected), "Startup work has a finite admission budget")
        }
        bounded.complete()
        try require(calls == 8, "Only admitted work is executed")

        let duringFlush = NativeCapabilityGate(), retired = NativeRunToken()
        _ = duringFlush.admit { retired.cancel() }
        _ = duringFlush.admit(token: retired, { effects.append("retired during flush") })
        duringFlush.complete()
        try require(effects == ["replacement"], "The gate rechecks each intent immediately before delivery")
    }

    /// Missing, idle, stale and disconnected samples must remain distinct.
    static func testViewerDiagnostics() throws {
        func value(_ stats: NativeViewerDiagnostics, _ name: String) -> String? {
            stats.sections.flatMap(\.rows).first { $0.name == name }?.value
        }
        var stats = NativeViewerDiagnostics()
        try require(value(stats, "Received video") == "—" && value(stats, "Keyframe requests") == "—",
                    "Before connecting, missing samples aren't displayed as zero")
        stats.connected = true; stats.state = "Connected · view only"
        stats.local = [.receivedMbps: 0, .presentedFps: 0, .rttMs: 12.4]
        stats.host = [.bitrateMbps: 35, .fpsCap: 60, .encodeMs: 2.1]
        stats.totals = ["session_seconds": 3661, "keyframe_requests": 4, "decoder_overflows": 2]
        try require(value(stats, "Received video") == "0.00 Mbps" && value(stats, "Host bitrate target") == "—",
                    "A measured idle rate is zero; unsampled host data remains unavailable")
        stats.hostAge = 1
        try require(value(stats, "Host bitrate target") == "35.00 Mbps" && value(stats, "Presented / cap") == "0.0 / 60.0 fps",
                    "The host's target and frame cap are separate from measured throughput and presentation")
        try require(value(stats, "Network round trip") == "12.4 ms" && value(stats, "Screen → display")?.contains("— / —") == true,
                    "Network RTT is never substituted for unavailable screen-to-display latency")
        try require(value(stats, "Duration") == "1:01:01" && value(stats, "Keyframe requests") == "4" && value(stats, "Decode overflows") == "2",
                    "Elapsed time and recovery totals retain their own units")
        stats.hostAge = 3.1
        try require(stats.freshHost.isEmpty && stats.hostNotice.contains("stale") && value(stats, "Host encode") == "—",
                    "Old host samples expire instead of appearing live")
        stats.connected = false; stats.state = "Session ended"
        try require(value(stats, "Duration") == "—" && value(stats, "Network round trip") == "—" && value(stats, "Connection") == "Session ended",
                    "Ending a session clears live values even if its last sample remains in memory")
        try require(NativeViewerDiagnostics.number(.nan) == "—" && NativeViewerDiagnostics.number(-1) == "—",
                    "Invalid measurements aren't rendered as plausible numbers")
    }

    /// Real measurement mutations drive the subscriber; a burst cannot flood
    /// AppKit, expirations stop, and a stopped session cannot deliver late data.
    static func testViewerMeasurementStream() throws {
        let measurements = NativeSessionMeasurements()
        var samples: [NativeInterval] = []
        let stream = NativeViewerMeasurementStream(measurements: measurements, minimumInterval: 0.02,
                                                  expirations: [0.08, 0.16]) { samples.append($0) }
        measurements.observeChanges { [weak stream] in stream?.signal() }
        defer { measurements.observeChanges(nil); stream.stop() }
        func pump(_ seconds: TimeInterval) {
            let end = Date(timeIntervalSinceNow: seconds)
            while Date() < end { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
        }
        for _ in 0..<1_000 { measurements.add("received_video_bytes", 100) }
        let deadline = Date(timeIntervalSinceNow: 2)
        while samples.isEmpty && Date() < deadline { pump(0.005) }
        try require(samples.count == 1 && samples[0].values["received_video_bytes"] == 100_000,
                    "A burst is coalesced into one push containing the newest measurements")
        pump(0.25)
        try require(samples.count >= 2 && samples.count <= 3,
                    "Only the two bounded one-shot expirations may follow a quiet stream")
        let quiet = samples.count
        pump(0.06)
        try require(samples.count == quiet, "A quiet stats subscriber has no repeating refresh timer")
        measurements.add("received_video_bytes", 12)
        stream.stop(); pump(0.06)
        try require(samples.count == quiet, "Stopping a session cancels its queued UI push")
    }

    /// Synthetic session observations and fake power APIs only: no live wake.
    static func testWakeRecovery() throws {
        var held = 0, received: [IOPMAssertionID] = [], released: [IOPMAssertionID] = []
        let activity = NativeWakeActivity(createHold: { held += 1; return 99 }, declare: { id in
            received.append(id); id = UInt32(received.count + 40); return true
        }, release: { released.append($0) })
        var wake = MLHostWake()
        func step(_ ms: UInt32, share: Bool = false, awake: Bool = true) -> Int32 {
            ml_host_wake_step(&wake, ms, 1, share ? 1 : 0, awake ? 1 : 0)
        }
        try require(step(0, awake: false) == ML_HOST_WAKE_DECLARE_ACTIVITY && activity.request(),
                    "An approved connection starts one wake while the display is off")
        try require(step(100) == ML_HOST_WAKE_WAIT && released.isEmpty && held == 1,
                    "The activity and display hold remain owned while loginwindow is still covered")
        try require(step(1000) == ML_HOST_WAKE_DECLARE_ACTIVITY && activity.request(),
                    "A shield that missed the first activity gets a second request")
        try require(received == [0, 41], "A renewed activity passes the ID returned by IOKit")
        try require(step(1100, share: true) == ML_HOST_WAKE_READY,
                    "Clearing the shield permits a session only with an awake display")
        activity.stop(); activity.stop()
        try require(released == [42, 99] && !activity.request(), "Finishing releases each owned assertion once and prevents late activity")
        try require(ml_host_needs_unlock(1, 1) == 0 && ml_host_needs_unlock(1, 0) == 1,
                    "An eligible session clears a previous timeout regardless of display sleep; a covered session keeps it")

        var failedReleases: [IOPMAssertionID] = [], calls = 0
        do {
            let failed = NativeWakeActivity(createHold: { nil }, declare: { id in
                calls += 1
                if calls == 1 { id = 7; return true }
                id = 123; return false
            }, release: { failedReleases.append($0) })
            try require(failed.request() && !failed.request(), "An API failure is reported without discarding a previous successful activity")
        }
        try require(failedReleases == [7], "Dropping a canceled wake releases the last valid ID, not a failed output")
        var emptyReleases: [IOPMAssertionID] = []
        do {
            let empty = NativeWakeActivity(createHold: { nil }, declare: { _ in false }, release: { emptyReleases.append($0) })
            try require(!empty.request(), "A failed first request leaves no owned activity")
        }
        try require(emptyReleases.isEmpty, "Failed assertion creation requires no release")
    }
}
