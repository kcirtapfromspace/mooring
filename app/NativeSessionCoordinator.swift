import AppKit
import ApplicationServices
import SystemConfiguration
import CoreVideo

/// One visible host and one viewer per process. The Rust boundary owns the
/// authenticated wire; this class coordinates public Apple media/input APIs.
final class NativeSessionCoordinator {
    private let keychain = NativeKeychain()
    private let peerStore = NativePeerStore()
    private var shareWindow: NativeShareWindow?
    private var pairWindow: NativePairWindow?
    private var viewerWindow: NativeViewerWindow?
    private var listener: NativeTransport?
    private var sharingToken: NativeRunToken?
    private var hostIdentity: NativeHostIdentity?
    private var hostChannel: NativeSessionChannel?
    private var viewerChannel: NativeSessionChannel?
    private var capture: NativeCapture?
    private var decoder: NativeVideoDecoder?
    private var hostInjector: NativeInputInjector?
    private let inputEncoder = NativeInputEncoder()
    private let hostGeometryLock = NSLock()
    private var hostGeometry: NativeDisplayGeometry?
    private var viewerInputEnabled = false
    private var connectAttempt: NativeRunToken?
    private var statusTimer: Timer?
    private var permissionTimer: Timer?
    private var observerTokens: [NSObjectProtocol] = []
    private var privacyGuard: NativePrivacyGuard?
    private var firstFrame = false
    private var pingSequence: UInt64 = 0
    private var pendingPing: (UInt64, TimeInterval)?
    private var lastPresented: Double = 0
    private var lastStatusTime: TimeInterval = 0
    private var lastViewerMeasurements: NativeSessionMeasurements?
    private var lastHostMeasurements: NativeSessionMeasurements?
    private(set) var peers: [NativePeer] = []
    var onChange: (() -> Void)?
    var isSharing: Bool { sharingToken?.isActive == true }
    var isConnected: Bool { viewerChannel?.token.isActive == true }
    var status: String? {
        if isSharing { return hostChannel == nil ? "Sharing this Mac · waiting" : "Sharing this Mac · connected" }
        if isConnected { return "Native session connected" }
        return nil
    }
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init() {
        let defaults = ProcessInfo.processInfo.environment["MACLINK_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
        // Earlier builds kept peer metadata in preferences; Rust imports it once.
        if let legacy = defaults.data(forKey: "native.peers.v1"), (try? peerStore.importLegacy(legacy)) != nil {
            defaults.removeObject(forKey: "native.peers.v1")
        }
        peers = (try? peerStore.load()) ?? []
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.stopSharing(reason: "Sharing stopped while this Mac sleeps or its user session is inactive.")
                self?.disconnectViewer(reason: "This Mac went to sleep or changed user session. Reconnect when ready.")
            })
        }
        privacyGuard = NativePrivacyGuard { [weak self] in
            self?.stopSharing(reason: "Sharing stopped because this Mac locked or its display went to sleep. Start Sharing when ready.")
            self?.disconnectViewer(reason: "This Mac locked or its display went to sleep. Reconnect when ready.")
        }
    }

    func showShare() {
        if shareWindow == nil {
            let controller = NativeShareWindow(); shareWindow = controller
            controller.onToggle = { [weak self] in
                guard let self else { return }
                if self.isSharing { self.stopSharing() } else { self.startSharing() }
            }
            controller.onCopy = { [weak self] in self?.copyPairingCode() }
            controller.onReset = { [weak self] in self?.resetPairing() }
            controller.onControlPermission = { [weak self] in
                AppleSession.requestPermission()
                self?.shareWindow?.detail.stringValue = "Enable MacLink in macOS Accessibility to allow keyboard and mouse. Viewing works without it."
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
            }
            controller.onClose = { [weak self] in self?.stopSharing() }
            controller.onDiagnostics = { [weak self] in self?.saveDiagnostics(self?.lastHostMeasurements) }
        }
        refreshShare()
        shareWindow?.showWindow(nil); shareWindow?.window?.center(); NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshShare(_ message: String? = nil) {
        shareWindow?.toggle.title = isSharing ? "Stop Sharing" : "Start Sharing"
        shareWindow?.copy.isEnabled = isSharing
        shareWindow?.status.stringValue = isSharing ? (hostChannel == nil ? "Ready for your other Mac" : "Connected · sharing this display") : "Sharing is off"
        shareWindow?.control.isEnabled = !NativeInputInjector.isTrusted
        shareWindow?.control.title = NativeInputInjector.isTrusted ? "Keyboard & Mouse Enabled" : "Enable Keyboard & Mouse…"
        if let message { shareWindow?.detail.stringValue = message }
        onChange?()
    }

    private func startSharing() {
        guard !isSharing else { return }
        guard NativePrivacyGuard.mayShareNow() else {
            refreshShare("Unlock this Mac and sign in before starting sharing.")
            return
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            refreshShare("Allow MacLink in macOS Screen Recording, then click Start Sharing again.")
            return
        }
        do {
            let identity: NativeHostIdentity
            if let saved = try keychain.hostIdentity() { try saved.validate(); identity = saved }
            else { identity = try NativeHostIdentity.create(); try keychain.saveHostIdentity(identity) }
            let listener = try NativeTransport.listen(identity: identity)
            let token = NativeRunToken()
            self.listener = listener; sharingToken = token; hostIdentity = identity
            refreshShare("Copy the pairing code to your other Mac. Sharing stays on until you stop it or close this window.")
            acceptNext(listener: listener, token: token)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateHostPermission() }
            if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
        } catch { refreshShare(error.localizedDescription) }
    }

    private func acceptNext(listener: NativeTransport, token: NativeRunToken) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while token.isActive {
                do {
                    guard let transport = try listener.accept() else { continue }
                    DispatchQueue.main.async {
                        guard let self, token.isActive, self.sharingToken === token, self.hostChannel == nil else { transport.close(); return }
                        self.beginHost(transport, sharingToken: token)
                    }
                    return
                } catch {
                    // Invalid/unauthenticated peers do not change sharing state.
                    if !token.isActive { return }
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
        }
    }

    private func beginHost(_ transport: NativeTransport, sharingToken: NativeRunToken) {
        guard sharingToken.isActive, NativePrivacyGuard.mayShareNow() else {
            transport.close()
            stopSharing(reason: "Sharing stopped because this Mac is no longer active. Start Sharing when ready.")
            return
        }
        let channel = NativeSessionChannel(transport)
        hostChannel = channel; lastHostMeasurements = channel.measurements
        let injector = NativeInputInjector(); hostInjector = injector
        let capture = NativeCapture(); self.capture = capture
        channel.onFailure = { [weak self, weak channel] reason in
            guard let self, let channel, self.hostChannel === channel else { return }
            self.endHost(reason: reason)
        }
        capture.onGeometry = { [weak self, weak channel] geometry in
            guard let self, let channel, channel.token.isActive else { return }
            self.hostGeometryLock.lock(); self.hostGeometry = geometry; self.hostGeometryLock.unlock()
            channel.control(.geometry(geometry, inputEnabled: NativeInputInjector.isTrusted))
        }
        capture.onEncodedFrame = { [weak channel] frame, release in
            guard let channel, channel.token.isActive else { release(); return }
            channel.measurements.set("last_encode_ms", frame.metrics.encode_ms)
            channel.measurements.set("skipped_capture_frames", Double(frame.metrics.skipped_capture_frames))
            channel.measurements.set("capture_pixel_width", Double(frame.metrics.pixel_width))
            channel.measurements.set("capture_pixel_height", Double(frame.metrics.pixel_height))
            channel.measurements.set("target_bitrate", Double(frame.metrics.target_bitrate))
            channel.measurements.set("hardware_encoder_required", frame.metrics.hardware_encoder ? 1 : 0)
            channel.send(.video(frame.packet), completion: release)
        }
        capture.onError = { [weak channel] message in channel?.fail(message) }
        capture.start { [weak self, weak channel] result in
            guard let self, let channel, self.hostChannel === channel, channel.token.isActive else { return }
            switch result {
            case .success: self.refreshShare(NativeInputInjector.isTrusted ? "Encrypted session · keyboard and mouse enabled." : "Encrypted session · view only. Enable Keyboard & Mouse to allow control.")
            case .failure(let error): channel.fail(error.localizedDescription)
            }
        }
        readHost(channel, injector: injector)
        refreshShare()
    }

    private func updateHostPermission() {
        guard NativePrivacyGuard.mayShareNow() else {
            stopSharing(reason: "Sharing stopped because this Mac is no longer active. Start Sharing when ready.")
            return
        }
        shareWindow?.control.isEnabled = !NativeInputInjector.isTrusted
        shareWindow?.control.title = NativeInputInjector.isTrusted ? "Keyboard & Mouse Enabled" : "Enable Keyboard & Mouse…"
        guard let channel = hostChannel, channel.token.isActive else { return }
        if !NativeInputInjector.isTrusted { hostInjector?.releaseAll() }
        channel.control(.inputState(enabled: NativeInputInjector.isTrusted))
    }

    /// Rust admits only input, ping and keyframe requests here, enforces rate
    /// and spacing limits, and ends the session when the viewer goes idle.
    private func readHost(_ channel: NativeSessionChannel, injector: NativeInputInjector) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self, weak channel] in
            guard let self, let channel else { return }
            defer { injector.stop() }
            while channel.token.isActive {
                do {
                    guard let message = try channel.transport.receive() else { continue }
                    switch message {
                    case .input(let event):
                        guard NativePrivacyGuard.mayShareNow() else {
                            injector.stop(); channel.close()
                            DispatchQueue.main.async { [weak self] in
                                self?.stopSharing(reason: "Sharing stopped because this Mac is no longer active. Start Sharing when ready.")
                            }
                            return
                        }
                        self.hostGeometryLock.lock(); let geometry = self.hostGeometry; self.hostGeometryLock.unlock()
                        guard channel.token.isActive, NativeInputInjector.isTrusted, let g = geometry else { injector.releaseAll(); continue }
                        try injector.apply(event, displayBounds: CGRect(x: g.x, y: g.y, width: g.width, height: g.height))
                    case .control(.ping(let id)):
                        channel.control(.pong(id))
                    case .control(.keyframe):
                        DispatchQueue.main.async { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel, channel.token.isActive else { return }
                            self.capture?.requestKeyframe()
                        }
                    case .control, .video:
                        throw NativeSessionError(message: "The viewer sent an unexpected session message.")
                    }
                } catch { if channel.token.isActive { channel.fail(error.localizedDescription) }; return }
            }
        }
    }

    private func endHost(reason: String) {
        hostChannel?.close(); hostChannel = nil
        capture?.stop(); capture = nil; hostInjector?.stop(); hostInjector = nil
        hostGeometryLock.lock(); hostGeometry = nil; hostGeometryLock.unlock()
        refreshShare(reason + " Waiting for a new connection.")
        if let listener, let token = sharingToken, token.isActive { acceptNext(listener: listener, token: token) }
    }

    func stopSharing(reason: String = "Sharing stopped. Your paired Macs can reconnect the next time you start sharing.") {
        sharingToken?.cancel(); sharingToken = nil
        listener?.close(); listener = nil
        hostChannel?.close(); hostChannel = nil
        capture?.stop(); capture = nil; hostInjector?.stop(); hostInjector = nil
        permissionTimer?.invalidate(); permissionTimer = nil
        hostGeometryLock.lock(); hostGeometry = nil; hostGeometryLock.unlock()
        refreshShare(reason)
    }

    private func pairingCode() throws -> NativePairingCode {
        guard let identity = hostIdentity, isSharing else { throw NativeSessionError(message: "Start sharing before copying a pairing code.") }
        let localName = SCDynamicStoreCopyLocalHostName(nil) as String? ?? "localhost"
        return try NativePairingCode.forHost(address: localName + ".local", computerName: Host.current().localizedName ?? "Mac", identity: identity)
    }
    private func copyPairingCode() {
        do {
            let code = try pairingCode().encoded()
            // The code carries the long-lived pairing secret. The nspasteboard.org
            // concealed marker asks clipboard managers not to record or display it.
            let item = NSPasteboardItem()
            item.setString(code, forType: .string)
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item])
            shareWindow?.detail.stringValue = "Pairing code copied. Paste it into Connect with MacLink on your other Mac."
        } catch { refreshShare(error.localizedDescription) }
    }
    private func resetPairing() {
        stopSharing(reason: "Pairing reset requested.")
        do { let identity = try NativeHostIdentity.create(); try keychain.saveHostIdentity(identity); hostIdentity = identity
            refreshShare("Previous codes no longer work. Start sharing and copy a new code to pair again.")
        } catch { refreshShare(error.localizedDescription) }
    }

    func showConnect() {
        if let viewerWindow, isConnected { viewerWindow.showWindow(nil); NSApp.activate(ignoringOtherApps: true); return }
        if pairWindow == nil {
            let controller = NativePairWindow(); pairWindow = controller
            controller.onConnect = { [weak self] rawCode, override in
                guard let self else { return }
                do {
                    let code = try NativePairingCode.parse(rawCode)
                    let address = override.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.connect(code: code, address: address.isEmpty ? code.address : address)
                } catch { self.pairWindow?.error.stringValue = error.localizedDescription }
            }
            controller.onClose = { [weak self] in self?.connectAttempt?.cancel(); self?.connectAttempt = nil }
        }
        pairWindow?.setBusy(false); pairWindow?.error.stringValue = ""
        pairWindow?.showWindow(nil); pairWindow?.window?.center(); NSApp.activate(ignoringOtherApps: true)
    }
    func connect(peerID: String) {
        if isConnected { viewerWindow?.showWindow(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let peer = peers.first(where: { $0.id == peerID }) else { return }
        do {
            guard let code = try keychain.peerCode(peerID) else { showConnect(); return }
            connect(code: code, address: peer.address)
        } catch { showError(error.localizedDescription) }
    }
    private func connect(code: NativePairingCode, address: String) {
        guard !isConnected, connectAttempt == nil else { return }
        guard let address = NativePairingCode.normalizedAddress(address) else { pairWindow?.error.stringValue = "Enter a hostname or IP address without a port."; return }
        let attempt = NativeRunToken(); connectAttempt = attempt
        pairWindow?.setBusy(true); pairWindow?.error.stringValue = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let transport = try NativeTransport.connect(address: address, code: code)
                DispatchQueue.main.async {
                    guard let self, attempt.isActive, self.connectAttempt === attempt else { transport.close(); return }
                    self.connectAttempt = nil; self.pairWindow?.setBusy(false)
                    do {
                        // Keychain is required to reconnect later. The menu list is a
                        // convenience: an unwritable peer file must not block this session.
                        try self.keychain.savePeerCode(code)
                        let peer = (try? self.peerStore.remember(code, address: address)) ?? NativePeer(code: code, address: address)
                        self.peers = (try? self.peerStore.load()) ?? self.peers
                        self.pairWindow?.code.stringValue = ""; self.pairWindow?.close()
                        self.beginViewer(transport, peer: peer)
                    } catch { transport.close(); self.showError(error.localizedDescription) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, attempt.isActive, self.connectAttempt === attempt else { return }
                    self.connectAttempt = nil; self.pairWindow?.setBusy(false)
                    if self.pairWindow?.window?.isVisible == true { self.pairWindow?.error.stringValue = error.localizedDescription }
                    else { self.showError(error.localizedDescription) }
                }
            }
        }
    }

    private func beginViewer(_ transport: NativeTransport, peer: NativePeer) {
        let channel = NativeSessionChannel(transport), decoder = NativeVideoDecoder()
        viewerChannel = channel; self.decoder = decoder; lastViewerMeasurements = channel.measurements
        firstFrame = false; viewerInputEnabled = false; pendingPing = nil; lastPresented = 0; lastStatusTime = uptime
        // Retired windows cannot act on a later connection.
        viewerWindow?.onClose = nil; viewerWindow?.onReleaseInput = nil
        viewerWindow?.video.onInput = nil; viewerWindow?.video.onReleaseInput = nil
        viewerWindow?.close()
        let window = NativeViewerWindow(name: peer.name); viewerWindow = window
        window.onClose = { [weak self, weak channel] in
            guard let self, let channel, self.viewerChannel === channel else { return }
            self.disconnectViewer(reason: "Disconnected.")
        }
        let release: () -> Void = { [weak self, weak channel] in
            guard let self, let channel, self.viewerChannel === channel else { return }
            self.releaseViewerInput()
        }
        window.onReleaseInput = release; window.video.onReleaseInput = release
        window.onDiagnostics = { [weak self, measurements = channel.measurements] in self?.saveDiagnostics(measurements) }
        window.video.onInput = { [weak self, weak channel] event in
            guard let self, let channel, self.viewerChannel === channel else { return }
            self.sendInput(event)
        }
        let firstPresentationPending = NativeRunToken()
        window.video.onPresented = { [weak self, weak channel] in
            guard let channel, channel.token.isActive else { return }
            channel.measurements.add("presented_frames")
            if firstPresentationPending.cancel() {
                channel.measurements.set("first_presented_frame_ms", channel.measurements.snapshot()["session_seconds", default: 0] * 1000)
                DispatchQueue.main.async {
                    guard let self, self.viewerChannel === channel, channel.token.isActive else { return }
                    self.firstFrame = true
                    if let window = self.viewerWindow?.window, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                }
            }
        }
        channel.onFailure = { [weak self, weak channel] message in
            guard let self, let channel, self.viewerChannel === channel else { return }
            self.disconnectViewer(reason: message)
        }
        decoder.onNeedsKeyframe = { [weak channel] in channel?.control(.keyframe) }
        decoder.onError = { [weak channel] message in channel?.fail(message) }
        let firstFramePending = NativeRunToken()
        decoder.onFrame = { [weak channel, weak video = window.video] buffer in
            guard let channel, channel.token.isActive else { return }
            channel.measurements.add("decoded_frames")
            video?.display(buffer)
            if firstFramePending.cancel() {
                channel.measurements.set("first_decoded_frame_ms", channel.measurements.snapshot()["session_seconds", default: 0] * 1000)
            }
        }
        window.showWindow(nil); window.window?.center(); window.window?.makeFirstResponder(window.video)
        NSApp.activate(ignoringOtherApps: true)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateViewerStatus() }
        if let statusTimer { RunLoop.main.add(statusTimer, forMode: .common) }
        readViewer(channel, decoder: decoder)
        onChange?()
    }

    /// Rust admits only video, geometry, input state and pong here, requires
    /// geometry before video, limits control rate, and ends an idle session.
    private func readViewer(_ channel: NativeSessionChannel, decoder: NativeVideoDecoder) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak channel] in
            guard let self, let channel else { return }
            while channel.token.isActive {
                do {
                    guard let message = try channel.transport.receive() else { continue }
                    switch message {
                    case .video(let packet):
                        channel.measurements.add("received_video_frames"); channel.measurements.add("received_video_bytes", Double(packet.wireSize))
                        _ = decoder.decode(packet)
                    case .control(let control):
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.viewerChannel === channel, channel.token.isActive else { return }
                            self.apply(control, channel: channel)
                        }
                    case .input:
                        throw NativeSessionError(message: "The sharing Mac sent an unexpected input message.")
                    }
                } catch { if channel.token.isActive { channel.fail(error.localizedDescription) }; return }
            }
        }
    }
    private func apply(_ control: NativeControlMessage, channel: NativeSessionChannel) {
        switch control {
        case .geometry(let geometry, let enabled):
            viewerWindow?.video.geometry = geometry
            channel.measurements.set("capture_pixel_width", Double(geometry.pixelWidth))
            channel.measurements.set("capture_pixel_height", Double(geometry.pixelHeight))
            setViewerInput(enabled)
        case .inputState(let enabled):
            setViewerInput(enabled)
        case .pong(let id):
            if let outstanding = pendingPing, id == outstanding.0 {
                channel.measurements.set("network_round_trip_ms", (uptime - outstanding.1) * 1000)
                pendingPing = nil
            }
        case .ping, .keyframe:
            break
        }
    }
    private func setViewerInput(_ enabled: Bool) {
        if !enabled { releaseViewerInput() }
        viewerInputEnabled = enabled
    }

    private func sendInput(_ event: NSEvent) {
        guard let channel = viewerChannel, channel.token.isActive, viewerInputEnabled, firstFrame, NSApp.isActive,
              let window = viewerWindow?.window, window.isKeyWindow,
              let view = viewerWindow?.video, window.firstResponder === view, view.geometry != nil,
              view.displayedVideoRect.width > 0, view.displayedVideoRect.height > 0,
              let input = inputEncoder.encode(event, in: view, contentRect: view.displayedVideoRect) else { return }
        channel.send(.input(input))
    }
    private func releaseViewerInput() {
        let event = inputEncoder.releaseAll()
        guard let channel = viewerChannel, channel.token.isActive else { return }
        channel.send(.input(event))
    }
    private func updateViewerStatus() {
        guard let channel = viewerChannel, channel.token.isActive else { return }
        let now = uptime, snapshot = channel.measurements.snapshot()
        let count = snapshot["presented_frames", default: 0]
        let fps = (count - lastPresented) / max(0.001, now - lastStatusTime)
        lastPresented = count; lastStatusTime = now
        channel.measurements.set("last_presented_fps", fps)
        let rtt = snapshot["network_round_trip_ms"].map { String(format: "%.0f ms RTT", $0) } ?? "checking connection"
        viewerWindow?.status.stringValue = "\(viewerInputEnabled ? "Connected" : "View only") · \(String(format: "%.0f", fps)) fps · \(rtt)"
        if let pendingPing, now - pendingPing.1 > 8 { channel.fail("The sharing Mac stopped answering connection checks."); return }
        if pendingPing == nil {
            pingSequence &+= 1; pendingPing = (pingSequence, now)
            channel.control(.ping(pingSequence))
        }
    }
    func disconnectViewer(reason: String) {
        connectAttempt?.cancel(); connectAttempt = nil
        releaseViewerInput(); viewerChannel?.close(); viewerChannel = nil
        decoder?.stop(); decoder = nil; viewerInputEnabled = false
        statusTimer?.invalidate(); statusTimer = nil
        viewerWindow?.status.stringValue = reason
        // Remove the last remote frame as soon as the authenticated session ends.
        viewerWindow?.video.clearFrame()
        onChange?()
    }

    private func saveDiagnostics(_ measurements: NativeSessionMeasurements?) {
        guard let measurements else { showError("Connect a native session before saving diagnostics."); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "MacLink-diagnostics.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try measurements.report().write(to: url, options: .atomic) }
        catch { showError("Could not save diagnostics: \(error.localizedDescription)") }
    }
    private func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = "MacLink connection"; alert.informativeText = message; alert.runModal()
    }
    func stop() {
        stopSharing(); disconnectViewer(reason: "MacLink stopped.")
        privacyGuard?.stop(); privacyGuard = nil
        observerTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observerTokens.removeAll()
    }
}
