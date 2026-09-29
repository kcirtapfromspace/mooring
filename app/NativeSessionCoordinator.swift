import AppKit
import ApplicationServices
import SystemConfiguration
import CoreVideo

/// Host input checks run on the network thread for every event. Session
/// eligibility and permission are re-read at most every 250 ms rather than per
/// event; lock and sleep notifications still end the session at once.
private final class NativeHostInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var checked: TimeInterval?
    private var state = (eligible: false, trusted: false)
    func current() -> (eligible: Bool, trusted: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        if let checked, now >= checked, now - checked < 0.25 { return state }
        state = (NativePrivacyGuard.mayShareNow(), NativeInputInjector.isTrusted); checked = now
        return state
    }
    func invalidate() { lock.lock(); checked = nil; lock.unlock() }
}

/// Encoder counters from captures a restart retired, so session totals never
/// go backward when a new encoder starts from zero.
private struct NativeEncoderCounters {
    var skipped: UInt64 = 0, dropped: UInt64 = 0, failed: UInt64 = 0
    mutating func add(_ metrics: NativeMediaMetrics) {
        skipped &+= metrics.skipped_capture_frames; dropped &+= metrics.dropped_frames; failed &+= metrics.failed_frames
    }
    func adding(_ metrics: NativeMediaMetrics?) -> NativeEncoderCounters {
        var total = self
        if let metrics { total.add(metrics) }
        return total
    }
}

/// One visible host and one viewer per process. The Rust boundary owns the
/// authenticated wire; this class coordinates public Apple media/input APIs.
final class NativeSessionCoordinator {
    private static let automaticSharingKey = "native.shareAutomatically"
    private let defaults: UserDefaults
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
    private let hostInputGate = NativeHostInputGate()
    private let inputEncoder = NativeInputEncoder()
    private let hostGeometryLock = NSLock()
    private var hostGeometry: NativeDisplayGeometry?
    private var viewerInputEnabled = false
    /// At most one connect is in flight: a pairing from the form, or a
    /// connect or reconnect to a saved pairing.
    private var connecting: (token: NativeRunToken, peerID: String, pairing: Bool)?
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
    /// Idle display and system sleep would end an active session, so each side
    /// holds a power assertion only while a viewer is connected.
    private var hostActivity: NSObjectProtocol?
    private var viewerActivity: NSObjectProtocol?
    /// The sharing side's stream settings for this app run; tuning changes them live.
    private var hostTuning = NativeTuning.defaults
    private var telemetryTimer: Timer?
    /// The running capture's liveness. A restart cancels it first, so callbacks
    /// from the retired capture never reach the session.
    private var captureToken: NativeRunToken?
    private var captureMaxWidth = 0
    private var captureRestartScheduled = false
    private var lastCaptureRestart: TimeInterval?
    private var retiredEncoderCounters = NativeEncoderCounters()
    /// Why the latest session on this Mac ended, for the log and telemetry.
    private var lastEnd: (reason: String, at: TimeInterval)?
    /// Automatic viewer reconnects after an unexpected end; Rust sets the budget.
    private var viewerStarted: TimeInterval = 0
    private var reconnectAttempts = 0
    private var reconnectWork: DispatchWorkItem?
    private var lastViewerEnd = ""
    /// Sends ⌘-Tab and other system shortcuts to the remote Mac while it has focus.
    private var systemKeys: NativeSystemKeyCapture?
    /// Stop Sharing holds automatic sharing off until sharing is started again.
    private var userStoppedSharing = false
    private var nextAutomaticShare: TimeInterval = 0
    private(set) var peers: [NativePeer] = [] { didSet { if peers != oldValue { onPeersChange?() } } }
    var onChange: (() -> Void)?
    var onPeersChange: (() -> Void)?
    var isSharing: Bool { sharingToken?.isActive == true }
    var isConnected: Bool { viewerChannel?.token.isActive == true }
    /// Start sharing when MacLink opens and resume after sleep, lock or a user switch.
    var sharesAutomatically: Bool {
        get { defaults.bool(forKey: Self.automaticSharingKey) }
        set { defaults.set(newValue, forKey: Self.automaticSharingKey) }
    }
    var status: String? {
        if isSharing { return hostChannel == nil ? "Sharing this Mac · waiting" : "Sharing this Mac · connected" }
        if isConnected { return "Native session connected" }
        return nil
    }
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init() {
        defaults = ProcessInfo.processInfo.environment["MACLINK_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
        // Earlier builds kept peer metadata in preferences; Rust imports it once.
        if let legacy = defaults.data(forKey: "native.peers.v1"), (try? peerStore.importLegacy(legacy)) != nil {
            defaults.removeObject(forKey: "native.peers.v1")
        }
        peers = (try? peerStore.load()) ?? []
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observerTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.stopSharing(reason: self.pausedReason("Sharing stopped while this Mac sleeps or its user session is inactive."))
                self.disconnectViewer(reason: "This Mac went to sleep or changed user session. Reconnect when ready.")
            })
        }
        // Owner-only local socket; a second running copy leaves it to the first.
        NativeTelemetryServer.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.telemetryTick() }
        RunLoop.main.add(timer, forMode: .common); telemetryTimer = timer
        privacyGuard = NativePrivacyGuard { [weak self] in
            guard let self else { return }
            self.stopSharing(reason: self.pausedReason("Sharing stopped because this Mac locked or its display went to sleep."))
            self.disconnectViewer(reason: "This Mac locked or its display went to sleep. Reconnect when ready.")
        }
        DispatchQueue.main.async { [weak self] in self?.resumeSharingIfAutomatic() }
    }

    func showShare() {
        if shareWindow == nil {
            let controller = NativeShareWindow(); shareWindow = controller
            controller.onToggle = { [weak self] in
                guard let self else { return }
                if self.isSharing { self.stopSharingByUser() } else { self.userStoppedSharing = false; self.startSharing() }
            }
            controller.onCopy = { [weak self] in self?.copyPairingCode() }
            controller.onReset = { [weak self] in self?.resetPairing() }
            controller.onControlPermission = { [weak self] in
                AppleSession.requestPermission()
                self?.shareWindow?.detail.stringValue = "Enable MacLink in macOS Accessibility to allow keyboard and mouse. Viewing works without it."
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
            }
            controller.onAutomaticChange = { [weak self] enabled in
                guard let self else { return }
                self.sharesAutomatically = enabled
                NativeLog.session.notice("automatic sharing \(enabled ? "on" : "off", privacy: .public)")
                if enabled && !self.isSharing { self.userStoppedSharing = false; self.startSharing() } else { self.refreshShare() }
            }
            controller.onDiagnostics = { [weak self] in self?.saveDiagnostics(self?.lastHostMeasurements) }
        }
        refreshShare()
        shareWindow?.showWindow(nil); shareWindow?.window?.center(); NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshShare(_ message: String? = nil) {
        shareWindow?.toggle.title = isSharing ? "Stop Sharing" : "Start Sharing"
        shareWindow?.copy.isEnabled = isSharing
        let idle = sharesAutomatically && !userStoppedSharing ? "Sharing paused · resumes automatically" : "Sharing is off"
        shareWindow?.status.stringValue = isSharing ? (hostChannel == nil ? "Ready for your other Mac" : "Connected · sharing this display") : idle
        shareWindow?.control.isEnabled = !NativeInputInjector.isTrusted
        shareWindow?.control.title = NativeInputInjector.isTrusted ? "Keyboard & Mouse Enabled" : "Enable Keyboard & Mouse…"
        shareWindow?.automatic.state = sharesAutomatically ? .on : .off
        if let message { shareWindow?.detail.stringValue = message }
        onChange?()
    }

    /// Stop reasons say whether sharing comes back by itself.
    private func pausedReason(_ reason: String) -> String {
        sharesAutomatically && !userStoppedSharing
            ? reason + " Sharing resumes automatically when this Mac is awake and unlocked."
            : reason + " Start Sharing when ready."
    }

    /// Automatic starts never show a permission prompt; the first manual start asks once.
    private func startSharing(automatic: Bool = false) {
        guard !isSharing else { return }
        guard NativePrivacyGuard.mayShareNow() else {
            refreshShare("Unlock this Mac and sign in before starting sharing.")
            return
        }
        guard CGPreflightScreenCaptureAccess() || (!automatic && CGRequestScreenCaptureAccess()) else {
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
            NativeLog.session.notice("sharing started \(automatic ? "automatically" : "by the user", privacy: .public)")
            refreshShare("Copy the pairing code to your other Mac. Sharing continues after you close this window, until you stop it.")
            acceptNext(listener: listener, token: token)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateHostPermission() }
            if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
        } catch { refreshShare(error.localizedDescription) }
    }

    /// Runs at launch and once a second. Retries are spaced five seconds apart.
    private func resumeSharingIfAutomatic() {
        guard sharesAutomatically, !userStoppedSharing, !isSharing, uptime >= nextAutomaticShare,
              NativePrivacyGuard.displayIsAwake, NativePrivacyGuard.mayShareNow() else { return }
        nextAutomaticShare = uptime + 5
        startSharing(automatic: true)
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
            stopSharing(reason: pausedReason("Sharing stopped because this Mac is no longer active."))
            return
        }
        let channel = NativeSessionChannel(transport)
        hostChannel = channel; lastHostMeasurements = channel.measurements
        retiredEncoderCounters = NativeEncoderCounters(); hostInputGate.invalidate()
        NativeLog.session.notice("host session started")
        let injector = NativeInputInjector(); hostInjector = injector
        hostActivity = hostActivity ?? ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
            reason: "A paired Mac is viewing this display")
        channel.onFailure = { [weak self, weak channel] reason in
            guard let self, let channel, self.hostChannel === channel else { return }
            self.endHost(reason: reason)
        }
        startCapture(for: channel)
        readHost(channel, injector: injector)
        refreshShare()
    }

    /// Starts screen capture for a connected viewer using the current tuning.
    private func startCapture(for channel: NativeSessionChannel) {
        // While the viewer controls this Mac its own pointer is the cursor; drawing
        // this Mac's pointer into the video as well would show two.
        let tuning = hostTuning
        let capture = NativeCapture(maxPixelWidth: tuning.maxWidth, framesPerSecond: tuning.fps,
                                    showsCursor: !NativeInputInjector.isTrusted, bitrate: tuning.bitrate,
                                    keyframeSeconds: tuning.keyframeSeconds, inFlightLimit: tuning.inFlight)
        let live = NativeRunToken()
        captureToken?.cancel(); captureToken = live
        self.capture = capture; captureMaxWidth = tuning.maxWidth
        capture.onGeometry = { [weak self, weak channel] geometry in
            guard let self, let channel, live.isActive, channel.token.isActive else { return }
            self.hostGeometryLock.lock(); self.hostGeometry = geometry; self.hostGeometryLock.unlock()
            channel.measurements.set("capture_pixel_width", Double(geometry.pixelWidth))
            channel.measurements.set("capture_pixel_height", Double(geometry.pixelHeight))
            channel.control(.geometry(geometry, inputEnabled: NativeInputInjector.isTrusted))
        }
        capture.onCapturedFrame = { [weak channel] in if live.isActive { channel?.measurements.add("captured_frames") } }
        capture.onEncodedFrame = { [weak channel] frame, release in
            guard live.isActive, let channel, channel.token.isActive else { release(); return }
            // Per-frame values accumulate across capture restarts; the encoder's
            // own counters are sampled once a second.
            let measurements = channel.measurements
            measurements.set("last_encode_ms", frame.metrics.encode_ms)
            measurements.add("encoded_frames"); measurements.add("encode_ms_total", frame.metrics.encode_ms)
            measurements.recordMax("encode_ms", frame.metrics.encode_ms)
            if frame.keyframe { measurements.add("encoded_keyframes") }
            measurements.set("target_bitrate", Double(frame.metrics.target_bitrate))
            measurements.set("hardware_encoder_required", frame.metrics.hardware_encoder ? 1 : 0)
            channel.send(.video(frame.packet), completion: release)
        }
        capture.onError = { [weak self, weak channel] message in
            DispatchQueue.main.async {
                guard let self, let channel, live.isActive, self.hostChannel === channel else { return }
                channel.fail(message)
            }
        }
        capture.start { [weak self, weak channel] result in
            guard let self, let channel, live.isActive, self.hostChannel === channel, channel.token.isActive else { return }
            switch result {
            case .success: self.refreshShare(NativeInputInjector.isTrusted ? "Encrypted session · keyboard and mouse enabled." : "Encrypted session · view only. Enable Keyboard & Mouse to allow control.")
            case .failure(let error): channel.fail(error.localizedDescription)
            }
        }
    }

    /// Stops the running capture and keeps its encoder counters.
    private func retireCapture() {
        captureToken?.cancel(); captureToken = nil
        if let metrics = capture?.encoderMetrics { retiredEncoderCounters.add(metrics) }
        capture?.stop(); capture = nil
    }

    /// Applies a validated tuning update to the sharing side. Bitrate, frame
    /// rate, keyframe interval and in-flight frames change live; a new maximum
    /// width restarts capture at the new size.
    private func applyTuning(_ update: NativeTuning) {
        guard let tuning = hostTuning.merged(update) else { return }
        let previous = hostTuning
        hostTuning = tuning
        if tuning != previous {
            NativeLog.session.notice("tuning: \(tuning.bitrate / 1000) kbps, width \(tuning.maxWidth), \(tuning.fps) fps, in flight \(tuning.inFlight), keyframe \(tuning.keyframeSeconds) s")
        }
        guard let channel = hostChannel, channel.token.isActive, let capture else { return }
        if tuning.maxWidth != captureMaxWidth { scheduleCaptureRestart() }
        if tuning.bitrate != previous.bitrate { capture.setTargetBitrate(tuning.bitrate) }
        if tuning.fps != previous.fps { capture.setFrameRate(tuning.fps) }
        if tuning.keyframeSeconds != previous.keyframeSeconds { capture.setKeyframeSeconds(tuning.keyframeSeconds) }
        if tuning.inFlight != previous.inFlight { capture.setInFlightLimit(tuning.inFlight) }
    }

    /// Restarts are coalesced and at least a second apart, so a burst of width
    /// changes restarts capture once, at the latest width.
    private func scheduleCaptureRestart() {
        guard !captureRestartScheduled else { return }
        captureRestartScheduled = true
        let wait = lastCaptureRestart.map { max(0, $0 + 1 - uptime) } ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.captureRestartScheduled = false
            guard let channel = self.hostChannel, channel.token.isActive, self.capture != nil,
                  self.hostTuning.maxWidth != self.captureMaxWidth else { return }
            self.lastCaptureRestart = self.uptime
            NativeLog.session.notice("capture restarting at width \(self.hostTuning.maxWidth)")
            self.retireCapture()
            self.startCapture(for: channel)
        }
    }

    private func updateHostPermission() {
        guard NativePrivacyGuard.mayShareNow() else {
            stopSharing(reason: pausedReason("Sharing stopped because this Mac is no longer active."))
            return
        }
        hostInputGate.invalidate()
        let trusted = NativeInputInjector.isTrusted
        shareWindow?.control.isEnabled = !trusted
        shareWindow?.control.title = trusted ? "Keyboard & Mouse Enabled" : "Enable Keyboard & Mouse…"
        guard let channel = hostChannel, channel.token.isActive else { return }
        if !trusted { hostInjector?.releaseAll() }
        capture?.setShowsCursor(!trusted)
        channel.control(.inputState(enabled: trusted))
    }

    /// Rust admits only input, ping and keyframe requests here, enforces rate
    /// and spacing limits, and ends the session when the viewer goes idle.
    private func readHost(_ channel: NativeSessionChannel, injector: NativeInputInjector) {
        let gate = hostInputGate
        DispatchQueue.global(qos: .userInteractive).async { [weak self, weak channel] in
            guard let self, let channel else { return }
            defer { injector.stop() }
            while channel.token.isActive {
                do {
                    guard let message = try channel.transport.receive() else { continue }
                    switch message {
                    case .input(let event):
                        let allowed = gate.current()
                        guard allowed.eligible else {
                            injector.stop(); channel.close()
                            DispatchQueue.main.async { [weak self] in
                                guard let self else { return }
                                self.stopSharing(reason: self.pausedReason("Sharing stopped because this Mac is no longer active."))
                            }
                            return
                        }
                        self.hostGeometryLock.lock(); let geometry = self.hostGeometry; self.hostGeometryLock.unlock()
                        guard channel.token.isActive, allowed.trusted, let g = geometry else { injector.releaseAll(); continue }
                        try injector.apply(event, displayBounds: CGRect(x: g.x, y: g.y, width: g.width, height: g.height))
                    case .control(.ping(let id)):
                        channel.control(.pong(id))
                    case .control(.keyframe):
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel else { return }
                            self.capture?.requestKeyframe()
                        }
                    case .telemetry(.stats(let stats)):
                        channel.storePeerStats(stats)
                    case .telemetry(.tuning(let tuning)):
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel else { return }
                            self.applyTuning(tuning)
                        }
                    case .control, .video:
                        throw NativeSessionError(message: "The viewer sent an unexpected session message.")
                    }
                } catch { if channel.token.isActive { channel.fail(error.localizedDescription) }; return }
            }
        }
    }

    private func endHost(reason: String) {
        recordEnd("host", reason)
        hostChannel?.close(); hostChannel = nil
        endHostActivity()
        retireCapture(); hostInjector?.stop(); hostInjector = nil
        hostGeometryLock.lock(); hostGeometry = nil; hostGeometryLock.unlock()
        refreshShare(reason + " Waiting for a new connection.")
        if let listener, let token = sharingToken, token.isActive { acceptNext(listener: listener, token: token) }
    }

    /// Stop Sharing in the window or menu. Automatic sharing stays off until
    /// the user starts sharing again or MacLink next opens.
    func stopSharingByUser() {
        userStoppedSharing = true
        stopSharing(reason: sharesAutomatically
            ? "Sharing stopped. It starts automatically again the next time MacLink opens, or click Start Sharing."
            : "Sharing stopped. Your paired Macs can reconnect the next time you start sharing.")
    }

    private func stopSharing(reason: String = "Sharing stopped. Your paired Macs can reconnect the next time you start sharing.") {
        if hostChannel != nil { recordEnd("host", reason) }
        if sharingToken != nil { NativeLog.session.notice("sharing stopped: \(reason, privacy: .public)") }
        sharingToken?.cancel(); sharingToken = nil
        listener?.close(); listener = nil
        hostChannel?.close(); hostChannel = nil
        endHostActivity()
        retireCapture(); hostInjector?.stop(); hostInjector = nil
        permissionTimer?.invalidate(); permissionTimer = nil
        hostGeometryLock.lock(); hostGeometry = nil; hostGeometryLock.unlock()
        refreshShare(reason)
    }

    private func endHostActivity() {
        if let hostActivity { ProcessInfo.processInfo.endActivity(hostActivity) }
        hostActivity = nil
    }

    /// Reasons are MacLink's own text or fixed Rust and Apple error text: never
    /// addresses, names or pairing material, so they are logged as public.
    private func recordEnd(_ role: String, _ reason: String) {
        lastEnd = (reason, uptime)
        NativeLog.session.notice("\(role, privacy: .public) session ended: \(reason, privacy: .public)")
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
                    self.connect(code: code, address: address.isEmpty ? code.address : address, pairing: true)
                } catch { self.pairWindow?.error.stringValue = error.localizedDescription }
            }
            controller.onClose = { [weak self] in if self?.connecting?.pairing == true { self?.cancelConnect() } }
        }
        pairWindow?.setBusy(false); pairWindow?.error.stringValue = ""
        pairWindow?.showWindow(nil); pairWindow?.window?.center(); NSApp.activate(ignoringOtherApps: true)
    }
    /// Remove a pairing from this Mac: its saved metadata and its Keychain secret.
    func forget(peerID: String) throws {
        try peerStore.forget(peerID)
        try keychain.deletePeerCode(peerID)
        peers = (try? peerStore.load()) ?? peers.filter { $0.id != peerID }
    }
    /// A user's connect or Reconnect click; it starts a fresh reconnect budget.
    func connect(peerID: String) {
        if isConnected { viewerWindow?.showWindow(nil); NSApp.activate(ignoringOtherApps: true); return }
        stopReconnecting()
        startConnect(peerID: peerID)
    }
    private func startConnect(peerID: String, automatic: Bool = false) {
        guard let peer = peers.first(where: { $0.id == peerID }) else {
            openViewerWindow(for: peerID)?.showEnded(reason: "This pairing was removed from this Mac.")
            return
        }
        do {
            guard let code = try keychain.peerCode(peerID) else {
                stopReconnecting()
                openViewerWindow(for: peerID)?.showEnded(reason: "This Mac's saved pairing is missing. Pair again with a new code.")
                showConnect(); return
            }
            connect(code: code, address: peer.address, automatic: automatic)
        } catch { connectFailed(error, peerID: peerID) }
    }
    /// `automatic` attempts come from the reconnect budget: they never bring
    /// MacLink forward or take keyboard focus from another app.
    private func connect(code: NativePairingCode, address: String, pairing: Bool = false, automatic: Bool = false) {
        guard !isConnected else { return }
        if let current = connecting {
            // A new pairing takes over from automatic reconnecting; anything else waits.
            guard pairing, !current.pairing else { return }
            endReconnecting(reason: lastViewerEnd.isEmpty ? "Reconnecting stopped for a new pairing." : lastViewerEnd)
        }
        guard let address = NativePairingCode.normalizedAddress(address) else { pairWindow?.error.stringValue = "Enter a hostname or IP address without a port."; return }
        let attempt = NativeRunToken(), peerID = code.peerID
        connecting = (attempt, peerID, pairing)
        if pairing { pairWindow?.setBusy(true); pairWindow?.error.stringValue = "" }
        if let window = openViewerWindow(for: peerID) {
            window.status.stringValue = "Connecting…"
            if !window.isReconnecting { window.showConnecting() }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let transport = try NativeTransport.connect(address: address, code: code)
                DispatchQueue.main.async {
                    guard let self, attempt.isActive, self.connecting?.token === attempt else { transport.close(); return }
                    self.connecting = nil
                    if pairing { self.pairWindow?.setBusy(false) }
                    // A saved pairing is already stored; only a new pairing writes.
                    guard pairing else {
                        let peer = self.peers.first(where: { $0.id == peerID }) ?? NativePeer(code: code, address: address)
                        self.beginViewer(transport, peer: peer, activate: !automatic)
                        return
                    }
                    do {
                        // Keychain is required to reconnect later. The menu list is a
                        // convenience: an unwritable peer file must not block this session.
                        try self.keychain.savePeerCode(code)
                        let peer = (try? self.peerStore.remember(code, address: address)) ?? NativePeer(code: code, address: address)
                        self.peers = (try? self.peerStore.load()) ?? self.peers
                        self.pairWindow?.code.stringValue = ""; self.pairWindow?.close()
                        self.beginViewer(transport, peer: peer, activate: true)
                    } catch { transport.close(); self.connectFailed(error, peerID: peerID, pairing: true) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, attempt.isActive, self.connecting?.token === attempt else { return }
                    self.connecting = nil
                    if pairing { self.pairWindow?.setBusy(false) }
                    self.connectFailed(error, peerID: peerID, pairing: pairing)
                }
            }
        }
    }
    /// Pairing reports in its form. A window already showing this Mac reports
    /// in place and retries within the budget; a first connect shows an alert.
    private func connectFailed(_ error: Error, peerID: String, pairing: Bool = false) {
        let message = error.localizedDescription
        if pairing {
            if pairWindow?.window?.isVisible == true { pairWindow?.error.stringValue = message } else { showError(message) }
            return
        }
        guard let window = openViewerWindow(for: peerID) else { showError(message); return }
        NativeLog.session.notice("viewer connect failed: \(message, privacy: .public)")
        window.status.stringValue = message
        if (error as? NativeSessionError)?.isAuthenticationFailure == true {
            stopReconnecting()
            window.showEnded(reason: "The sharing Mac did not accept this pairing. Pair again with a new code from that Mac.")
            return
        }
        let reason = lastViewerEnd.isEmpty ? message : lastViewerEnd
        if !scheduleReconnect(window, reason: reason) {
            window.showEnded(reason: lastViewerEnd.isEmpty ? message : "\(lastViewerEnd) Reconnecting failed: \(message)")
        }
    }
    private func cancelConnect() {
        if connecting?.pairing == true { pairWindow?.setBusy(false) }
        connecting?.token.cancel(); connecting = nil
    }

    /// The open window already showing this paired Mac, if any.
    private func openViewerWindow(for peerID: String) -> NativeViewerWindow? {
        guard let window = viewerWindow, window.peerID == peerID, !window.isClosed else { return nil }
        return window
    }
    /// Schedules the next automatic attempt; false once Rust's budget is spent.
    private func scheduleReconnect(_ window: NativeViewerWindow, reason: String) -> Bool {
        let attempt = reconnectAttempts + 1
        let milliseconds = ml_reconnect_delay_ms(UInt32(attempt))
        guard milliseconds >= 0 else { reconnectAttempts = 0; return false }
        reconnectAttempts = attempt
        window.showReconnecting(reason: reason, attempt: attempt, of: Int(ML_RECONNECT_ATTEMPTS))
        NativeLog.session.notice("viewer reconnect \(attempt) of \(ML_RECONNECT_ATTEMPTS) in \(milliseconds) ms")
        reconnectWork?.cancel()
        let peerID = window.peerID
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWork = nil
            guard !self.isConnected, let window = self.openViewerWindow(for: peerID) else { return }
            // A pairing in flight holds the only connect slot; count this attempt and wait.
            guard self.connecting == nil else {
                if !self.scheduleReconnect(window, reason: reason) { window.showEnded(reason: reason) }
                return
            }
            self.startConnect(peerID: peerID, automatic: true)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(milliseconds)), execute: work)
        return true
    }
    private func stopReconnecting() {
        reconnectWork?.cancel(); reconnectWork = nil; reconnectAttempts = 0
    }
    /// Stops reconnecting and any connect in flight; a window still saying
    /// "Reconnecting…" shows `reason` instead.
    private func endReconnecting(reason: String) {
        stopReconnecting(); cancelConnect()
        if viewerChannel == nil, let window = viewerWindow, !window.isClosed, window.isReconnecting { window.showEnded(reason: reason) }
    }

    private func beginViewer(_ transport: NativeTransport, peer: NativePeer, activate: Bool) {
        let channel = NativeSessionChannel(transport), decoder = NativeVideoDecoder()
        viewerChannel = channel; self.decoder = decoder; lastViewerMeasurements = channel.measurements
        firstFrame = false; viewerInputEnabled = false; pendingPing = nil; lastPresented = 0; lastStatusTime = uptime
        viewerStarted = uptime; reconnectWork?.cancel(); reconnectWork = nil
        NativeLog.session.notice("viewer session started\(self.reconnectAttempts > 0 ? " after reconnecting" : "", privacy: .public)")
        // Reconnecting keeps the window, and its full-screen space, for the same Mac.
        let window: NativeViewerWindow, reused = openViewerWindow(for: peer.id) != nil
        if let existing = openViewerWindow(for: peer.id) {
            window = existing; window.hideOverlay()
        } else {
            stopReconnecting()
            // Retired windows cannot act on a later connection.
            viewerWindow?.onClose = nil; viewerWindow?.onReleaseInput = nil
            viewerWindow?.video.onInput = nil; viewerWindow?.video.onReleaseInput = nil
            viewerWindow?.close()
            window = NativeViewerWindow(name: peer.name, peerID: peer.id); viewerWindow = window
        }
        viewerActivity = viewerActivity ?? ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
            reason: "Showing a paired Mac")
        window.onReconnect = { [weak self] in self?.connect(peerID: peer.id) }
        window.onCancelReconnect = { [weak self, weak window] in
            guard let self, let window, self.viewerWindow === window else { return }
            self.endReconnecting(reason: self.lastViewerEnd.isEmpty ? "Reconnecting was cancelled." : self.lastViewerEnd)
        }
        window.onAllowSystemKeys = {
            AppleSession.requestPermission()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
        }
        window.onClose = { [weak self, weak window] in
            guard let self, let window, self.viewerWindow === window else { return }
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
        // ⌘-Tab and other system shortcuts reach an app only through an event
        // tap, which needs Accessibility on this Mac.
        let keys = systemKeys ?? NativeSystemKeyCapture(); systemKeys = keys
        keys.isCapturing = { [weak self, weak channel] in
            guard let self, let channel, self.viewerChannel === channel else { return false }
            return self.viewerHasKeyboardFocus
        }
        keys.forward = { [weak self, weak channel] event in
            guard let self, let channel, self.viewerChannel === channel else { return }
            self.sendInput(event)
        }
        keys.onInterrupted = { [weak self, weak channel] in
            guard let self, let channel, self.viewerChannel === channel else { return }
            self.releaseViewerInput()
        }
        window.setSystemKeysAllowed(keys.start())
        let firstPresentationPending = NativeRunToken()
        window.video.onPresented = { [weak self, weak channel] in
            guard let channel, channel.token.isActive else { return }
            channel.measurements.add("presented_frames")
            if firstPresentationPending.cancel() {
                channel.measurements.set("first_presented_frame_ms", channel.measurements.snapshot()["session_seconds", default: 0] * 1000)
                DispatchQueue.main.async {
                    guard let self, self.viewerChannel === channel, channel.token.isActive, let viewer = self.viewerWindow else { return }
                    self.firstFrame = true
                    guard !viewer.hasShownVideo else { return }
                    viewer.hasShownVideo = true
                    if let window = viewer.window, !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
                }
            }
        }
        channel.onFailure = { [weak self, weak channel] message in
            guard let self, let channel, self.viewerChannel === channel else { return }
            self.disconnectViewer(reason: message, reconnect: true)
        }
        decoder.onNeedsKeyframe = { [weak channel] in channel?.measurements.add("keyframe_requests"); channel?.control(.keyframe) }
        decoder.onDecoded = { [weak channel] milliseconds in
            channel?.measurements.add("decode_ms_total", milliseconds); channel?.measurements.recordMax("decode_ms", milliseconds)
        }
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
        window.status.stringValue = "Connecting…"
        window.window?.makeFirstResponder(window.video)
        // An automatic reconnect reuses a window that is already open and leaves
        // focus where the user put it; input needs this window to be key anyway.
        if activate || !reused {
            window.showWindow(nil)
            if window.window?.styleMask.contains(.fullScreen) != true && !window.hasShownVideo { window.window?.center() }
            if activate { NSApp.activate(ignoringOtherApps: true) }
        }
        statusTimer?.invalidate()
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
                    case .telemetry(.stats(let stats)):
                        channel.storePeerStats(stats)
                    case .input, .telemetry(.tuning):
                        throw NativeSessionError(message: "The sharing Mac sent an unexpected message.")
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
        viewerWindow?.video.forwardsCommandKeys = enabled
        // View only: the sharing Mac draws its own pointer into the video, so
        // hide this Mac's pointer over it. With control, the reverse applies.
        viewerWindow?.video.hidesLocalCursor = !enabled
    }

    /// True while a connected, controlling session's video has keyboard focus.
    private var viewerHasKeyboardFocus: Bool {
        guard let channel = viewerChannel, channel.token.isActive, viewerInputEnabled, firstFrame, NSApp.isActive,
              let window = viewerWindow?.window, window.isKeyWindow,
              let view = viewerWindow?.video, window.firstResponder === view else { return false }
        return true
    }
    private func sendInput(_ event: NSEvent) {
        guard viewerHasKeyboardFocus, let channel = viewerChannel, let view = viewerWindow?.video, view.geometry != nil,
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
        // Accessibility can be granted mid-session; start capturing ⌘-Tab then.
        if let keys = systemKeys { viewerWindow?.setSystemKeysAllowed(keys.isRunning || keys.start()) }
        let now = uptime, snapshot = channel.measurements.snapshot()
        let count = snapshot["presented_frames", default: 0]
        let fps = (count - lastPresented) / max(0.001, now - lastStatusTime)
        lastPresented = count; lastStatusTime = now
        channel.measurements.set("last_presented_fps", fps)
        let rtt = snapshot["network_round_trip_ms"].map { String(format: "%.0f ms RTT", $0) } ?? "checking connection"
        // The sharing Mac sends frames only when its screen changes.
        let rate = fps < 0.5 ? "screen unchanged" : String(format: "%.0f fps", fps)
        let size = viewerWindow?.video.geometry.map { " · \($0.pixelWidth)×\($0.pixelHeight)" } ?? ""
        viewerWindow?.status.stringValue = "\(viewerInputEnabled ? "Connected" : "View only") · \(rate) · \(rtt)\(size)"
        if let pendingPing, now - pendingPing.1 > 8 { channel.fail("The sharing Mac stopped answering connection checks."); return }
        if pendingPing == nil {
            pingSequence &+= 1; pendingPing = (pingSequence, now)
            channel.control(.ping(pingSequence))
        }
    }
    /// `reconnect` is set only for an unexpected end. Privacy, sleep, quitting
    /// and closing the window end any reconnecting instead.
    func disconnectViewer(reason: String, reconnect: Bool = false) {
        if !reconnect { endReconnecting(reason: reason) }
        // Privacy and sleep events call this with no session; leave any window
        // from an earlier session showing its own reason.
        guard let channel = viewerChannel else { return }
        let lasted = uptime - viewerStarted
        recordEnd("viewer", reason); lastViewerEnd = reason
        releaseViewerInput(); channel.close(); viewerChannel = nil
        systemKeys?.stop()
        decoder?.stop(); decoder = nil; viewerInputEnabled = false
        statusTimer?.invalidate(); statusTimer = nil
        if let viewerActivity { ProcessInfo.processInfo.endActivity(viewerActivity) }
        viewerActivity = nil
        viewerWindow?.status.stringValue = reason
        // Remove the last remote frame as soon as the authenticated session ends,
        // and say why in place of the picture.
        viewerWindow?.video.clearFrame()
        viewerWindow?.video.hidesLocalCursor = false
        viewerWindow?.video.forwardsCommandKeys = false
        if reconnect, let window = viewerWindow, !window.isClosed {
            // A session that stayed up starts a fresh budget, so rare drops never exhaust it.
            if lasted >= Double(ML_RECONNECT_STABLE_SECONDS) { reconnectAttempts = 0 }
            if !scheduleReconnect(window, reason: reason) { window.showEnded(reason: reason) }
        } else {
            viewerWindow?.showEnded(reason: reason)
        }
        onChange?()
    }

    /// Once a second: resume automatic sharing, exchange stats with the
    /// connected Mac, apply or forward local tuning commands, and publish a
    /// snapshot on the local socket.
    private func telemetryTick() {
        resumeSharingIfAutomatic()
        if let tuning = NativeTelemetryServer.takeTuning() {
            if let channel = viewerChannel, channel.token.isActive, hostChannel == nil {
                channel.send(.telemetry(.tuning(tuning))) // the sharing Mac applies it
            } else {
                applyTuning(tuning) // this Mac shares, or keeps it for its next session
            }
        }
        let ended = lastEnd.map { (reason: $0.reason, age: uptime - $0.at) }
        var published = false
        for (channel, role, stats) in [(viewerChannel, Int(ML_ROLE_VIEWER), viewerStats), (hostChannel, Int(ML_ROLE_HOST), hostStats)] {
            guard let channel, channel.token.isActive else { continue }
            if role == Int(ML_ROLE_VIEWER), let decoder { channel.measurements.set("decoder_overflows", Double(decoder.overflows)) }
            if role == Int(ML_ROLE_HOST) {
                let totals = retiredEncoderCounters.adding(capture?.encoderMetrics)
                channel.measurements.set("skipped_capture_frames", Double(totals.skipped))
                channel.measurements.set("encoder_dropped_frames", Double(totals.dropped))
                channel.measurements.set("encoder_failed_frames", Double(totals.failed))
            }
            let interval = channel.measurements.nextInterval()
            let local = stats(interval)
            channel.send(.telemetry(.stats(local)))
            guard !published else { continue }
            let (peer, age) = channel.latestPeerStats()
            NativeTelemetryServer.publish(role: role, seconds: channel.measurements.snapshot()["session_seconds"] ?? 0,
                                          local: local, peer: peer, peerAge: age, tuning: hostTuning, lastEnd: ended)
            published = true
        }
        if !published {
            NativeTelemetryServer.publish(role: Int(ML_ROLE_IDLE), seconds: 0, local: [:], peer: [:], peerAge: nil,
                                          tuning: hostTuning, lastEnd: ended)
        }
    }
    private func hostStats(_ interval: NativeInterval) -> NativeStats {
        var stats: NativeStats = [
            .captureFps: interval.rate("captured_frames"), .encodedFps: interval.rate("encoded_frames"),
            .skippedFps: interval.rate("skipped_capture_frames"), .droppedFps: interval.rate("encoder_dropped_frames"),
            .failedFrames: interval.delta("encoder_failed_frames"), .keyframes: interval.delta("encoded_keyframes"),
            .sentMbps: interval.rate("sent_video_bytes") * 8 / 1_000_000, .inFlight: Double(capture?.inFlightCount ?? 0),
            .bitrateMbps: Double(hostTuning.bitrate) / 1_000_000, .fpsCap: Double(hostTuning.fps),
            .encodeMsMax: interval.maxima["encode_ms"] ?? 0, .sendMsMax: interval.maxima["video_send_ms"] ?? 0
        ]
        stats[.encodeMs] = interval.average("encode_ms_total", per: "encoded_frames")
        stats[.sendMs] = interval.average("video_send_ms_total", per: "sent_video_frames")
        stats[.frameKib] = interval.average("sent_video_bytes", per: "sent_video_frames").map { $0 / 1024 }
        stats[.pixelWidth] = interval.values["capture_pixel_width"]
        stats[.pixelHeight] = interval.values["capture_pixel_height"]
        return stats
    }
    private func viewerStats(_ interval: NativeInterval) -> NativeStats {
        var stats: NativeStats = [
            .receivedFps: interval.rate("received_video_frames"), .receivedMbps: interval.rate("received_video_bytes") * 8 / 1_000_000,
            .decodedFps: interval.rate("decoded_frames"), .presentedFps: interval.rate("presented_frames"),
            .keyframeRequests: interval.delta("keyframe_requests"), .decoderOverflows: interval.delta("decoder_overflows"),
            .decodeMsMax: interval.maxima["decode_ms"] ?? 0
        ]
        stats[.decodeMs] = interval.average("decode_ms_total", per: "decoded_frames")
        stats[.rttMs] = interval.values["network_round_trip_ms"]
        return stats
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
        telemetryTimer?.invalidate(); telemetryTimer = nil
        NativeTelemetryServer.stop()
        stopSharing(); disconnectViewer(reason: "MacLink stopped.")
        systemKeys?.stop(); systemKeys = nil
        privacyGuard?.stop(); privacyGuard = nil
        observerTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observerTokens.removeAll()
    }
}
