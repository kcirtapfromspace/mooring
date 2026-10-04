import AppKit
import IOKit.pwr_mgt
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
    var skipped: UInt64 = 0, dropped: UInt64 = 0, failed: UInt64 = 0, queueWaitMs: Double = 0
    mutating func add(_ metrics: NativeMediaMetrics) {
        skipped &+= metrics.skipped_capture_frames; dropped &+= metrics.dropped_frames; failed &+= metrics.failed_frames
        queueWaitMs += metrics.queue_wait_ms
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
    private static let sharedClipboardKey = "native.shareClipboard"
    private static let matchScreenKey = "native.matchScreen"
    private static let playSoundKey = "native.playSound"
    private static let lowLatencyDisplayKey = "native.lowLatencyDisplay"
    /// One-shot: sharing was on, but not automatic, when a viewer's requested
    /// update installed; share again after the relaunch.
    private static let resumeAfterUpdateKey = "native.resumeSharingAfterUpdate"
    /// Previews 28 saved a wait for a dropped viewer here; launch removes it.
    private static let oldWaitForViewerKey = "native.waitForViewerUntil"
    private let defaults: UserDefaults
    private let keychain = NativeKeychain()
    private let peerStore = NativePeerStore()
    /// Macs approved to connect to this one.
    private let deviceStore = NativeDeviceStore()
    private var shareWindow: NativeShareWindow?
    private var pairWindow: NativePairWindow?
    private var viewerWindow: NativeViewerWindow?
    private var listener: NativeTransport?
    private var sharingToken: NativeRunToken?
    private var hostIdentity: NativeHostIdentity?
    /// Waking this Mac for a viewer left its screen asking for a password, so
    /// automatic sharing waits for an unlock rather than wake it again.
    private var needsUnlock = false
    /// A viewer session this Mac's sleep or lock ended: reconnect to it once
    /// this Mac is awake and unlocked again.
    private var resumeAfterWake: String?
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
    /// Viewer: the sharing Mac's clock, and screen-change-to-display latency
    /// for the status bar (each second) and the log (every 10 s).
    private let clockSync = NativeClockSync()
    private var latencySecond = NativeLatencyWindow()
    private var latencyReport = NativeLatencyWindow()
    private var lastPresented: Double = 0
    private var lastStatusTime: TimeInterval = 0
    private var lastViewerMeasurements: NativeSessionMeasurements?
    /// Every 10 s the viewer logs where decoded frames went: drawn, waiting
    /// on the GPU, or replaced by newer ones. Local only; never sent.
    private var drawReportTicks = 0
    private var drawReportDecoded: Double = 0
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
    /// Host: the bitrate Rust's pacing chose, at most the tuned bitrate, and
    /// how many seconds the connection has been clear.
    private var flowKbps: UInt32 = 0
    private var flowState = MLFlowState()
    /// A keyframe went out in the last pacing second.
    private var keyframeLastSecond = false
    /// The link's rate measured in the last pacing second, kbit/s; 0 if not.
    private var lastLinkKbps: UInt32 = 0
    /// Host: the send-buffer limit, read on the capture queue and updated
    /// once a second from the last ten seconds' fastest round trip.
    private let flowLimit = NativeFlowLimit()
    /// Why the latest session on this Mac ended, for the log and telemetry.
    private var lastEnd: (reason: String, at: TimeInterval)?
    /// Automatic viewer reconnects after an unexpected end; Rust sets the budget.
    private var viewerStarted: TimeInterval = 0
    private var reconnectAttempts = 0
    private var reconnectWork: DispatchWorkItem?
    private var lastViewerEnd = ""
    /// Sends ⌘-Tab and other system shortcuts to the remote Mac while it has focus.
    private var systemKeys: NativeSystemKeyCapture?
    /// Found at launch by encoding and decoding one HEVC 4:4:4 frame in hardware.
    private var hevc444Available = false
    /// Found at launch by encoding and decoding a tone through Opus.
    private var audioAvailable = false
    /// A session announces this Mac's capabilities once, when it starts, so
    /// sharing and connecting wait for the launch self-tests (well under a
    /// second). Without this, a viewer that reconnected the moment this Mac
    /// relaunched after an update got H.264, no sound and no screen matching.
    private let capabilityGate = NativeCapabilityGate()
    private var capabilitiesReady: Bool { capabilityGate.isReady }
    /// Host: numbers the viewer's sound packets and bounds those waiting.
    private var hostAudioGate: NativeAudioSendGate?
    /// Viewer: plays the sharing Mac's sound.
    private var audioPlayer: NativeAudioPlayer?
    private var audioReported = NativeAudioStats()
    /// Host: follows this Mac's pointer shape for viewers that draw it.
    private let cursorWatcher = NativeCursorWatcher()
    /// Host: the display being shared, virtual when a viewer asked for its size.
    private let sharedDisplay = NativeSharedDisplay()
    private var pendingDisplayRequest: (width: Int, height: Int, scale: Int)?
    private var displayRequestScheduled = false
    private var displayRestarts: [TimeInterval] = []
    private var displayRestartScheduled = false
    /// Viewer: the last size observed and the last one requested.
    private var observedScreenRequest: (width: Int, height: Int, scale: Int)?
    private var sentScreenRequest: (width: Int, height: Int, scale: Int)?
    /// Exchanges this Mac's clipboard with a connected Mac, polled twice a second.
    private let clipboard = NativeClipboardSync()
    private var clipboardTimer: Timer?
    /// Stop Sharing holds automatic sharing off until sharing is started again.
    private var userStoppedSharing = false
    private var nextAutomaticShare: TimeInterval = 0
    private(set) var peers: [NativePeer] = [] { didSet { if peers != oldValue { onPeersChange?() } } }
    var onChange: (() -> Void)?
    var onPeersChange: (() -> Void)?
    /// A connection closed during the handshake, which usually means the Macs
    /// run different MacLink versions.
    var onVersionMismatch: (() -> Void)?
    /// Set by the app before launch self-tests finish: this is a release build
    /// that updates itself, so viewers may ask it to.
    var updatesItself = false
    /// Host: a viewer asked this Mac to check for an update now.
    var onUpdateRequest: (() -> Void)?
    /// Viewer: the sharing Mac is newer; check for an update to this Mac.
    var onCheckForUpdates: (() -> Void)?
    /// The other Mac's MacLink version in the current session, if it sent one.
    private(set) var viewerPeerVersion: NativeVersion?
    private(set) var hostPeerVersion: NativeVersion?
    /// Viewer: the sharing Mac's answer to "Update It".
    private var peerUpdate: (state: NativeUpdateState, ready: NativeVersion?, at: TimeInterval)?
    /// Viewer: disconnected so the sharing Mac could install an update, or it
    /// answered but isn't sharing, as when its screen asks for a password;
    /// wait for it to come back on Rust's longer schedule.
    private var awaitingPeer = false
    /// Viewer: counts Update It requests, so a timeout acts only on its own.
    private var updateRequestSerial = 0
    /// Host: a viewer was told its requested update is ready, so it installs
    /// when that session ends even if sharing isn't automatic.
    private var viewerAwaitsInstall = false
    /// Relaunching now would interrupt nothing: no session in either role, no
    /// connect or reconnect under way, and any sharing resumes by itself.
    var isIdleForUpdate: Bool {
        !isConnected && hostChannel == nil && connecting == nil && reconnectWork == nil
            && (!isSharing || sharesAutomatically || viewerAwaitsInstall)
    }
    var isSharing: Bool { sharingToken?.isActive == true }
    var isConnected: Bool { viewerChannel?.token.isActive == true }
    /// Start sharing when MacLink opens and resume after sleep, lock or a user switch.
    var sharesAutomatically: Bool {
        get { defaults.bool(forKey: Self.automaticSharingKey) }
        set { defaults.set(newValue, forKey: Self.automaticSharingKey) }
    }
    /// Copy on one Mac, paste on the other, while a session is connected. On by
    /// default; items marked private by password managers are never shared.
    var sharesClipboard: Bool {
        get { defaults.object(forKey: Self.sharedClipboardKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.sharedClipboardKey)
            NativeLog.session.notice("shared clipboard \(newValue ? "on" : "off", privacy: .public)")
            refreshClipboardScope(includeCurrent: false)
            shareWindow?.clipboard.state = newValue ? .on : .off
            onChange?()
        }
    }
    /// Viewer: ask a capable sharing Mac for a display the size of this Mac's
    /// video area, at Retina density. On by default.
    var matchesScreen: Bool {
        get { defaults.object(forKey: Self.matchScreenKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.matchScreenKey); onChange?() }
    }
    /// Viewer: hand frames to the display without waiting for its refresh.
    /// Off by default, since a fast-changing picture can tear.
    var lowersDisplayLatency: Bool {
        get { defaults.bool(forKey: Self.lowLatencyDisplayKey) }
        set {
            defaults.set(newValue, forKey: Self.lowLatencyDisplayKey)
            viewerWindow?.video.waitsForDisplayRefresh = !newValue
            onChange?()
        }
    }
    /// Viewer: play the sharing Mac's sound here. On by default; turning it
    /// off silences a running session at once.
    var playsSound: Bool {
        get { defaults.object(forKey: Self.playSoundKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.playSoundKey)
            audioPlayer?.setMuted(!newValue)
            onChange?()
        }
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
                self.pauseViewer(reason: "This Mac went to sleep or changed user session.")
            })
        }
        // Owner-only local socket; a second running copy leaves it to the first.
        NativeTelemetryServer.start()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.telemetryTick() }
        RunLoop.main.add(timer, forMode: .common); telemetryTimer = timer
        defaults.removeObject(forKey: Self.oldWaitForViewerKey)
        privacyGuard = NativePrivacyGuard { [weak self] in
            guard let self else { return }
            self.pauseSharing("This Mac locked or its display went to sleep.")
            self.pauseViewer(reason: "This Mac locked or its display went to sleep.")
        }
        // Announce HEVC 4:4:4 and sound only after this Mac has proven it can
        // encode and decode them. Sessions wait for this; if the tests stall,
        // they go ahead after 5 s with what needs no test.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hevc = NativeCodecSupport.probeHEVC444()
            let audio = NativeAudioSupport.probeOpus()
            DispatchQueue.main.async {
                guard let self, !self.capabilityGate.isStopped else { return }
                self.hevc444Available = hevc
                self.audioAvailable = audio
                let virtualDisplay = NativeSharedDisplay.isAvailable
                ml_capabilities_set(NativeCapabilities.local(hevc444: hevc, virtualDisplay: virtualDisplay, audio: audio,
                                                             updatesItself: self.updatesItself))
                NativeLog.session.notice("Opus sound encode and decode: \(audio ? "available" : "unavailable", privacy: .public)")
                NativeLog.session.notice("virtual display for viewers: \(virtualDisplay ? "available" : "unavailable", privacy: .public)")
                NativeLog.session.notice("HEVC 4:4:4 hardware encode and decode: \(hevc ? "available" : "unavailable", privacy: .public)")
                self.capabilitiesAreReady()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.capabilityGate.isStopped, !self.capabilitiesReady else { return }
            NativeLog.session.error("launch self-tests still running after 5 s; sessions start without HEVC 4:4:4 and sound")
            ml_capabilities_set(NativeCapabilities.local(hevc444: false, virtualDisplay: NativeSharedDisplay.isAvailable, audio: false,
                                                         updatesItself: self.updatesItself))
            self.capabilitiesAreReady()
        }
        cursorWatcher.onChange = { [weak self] image in
            guard let channel = self?.hostChannel, channel.token.isActive,
                  channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_CURSOR) != 0 else { return }
            channel.send(.cursor(image))
        }
        let poll = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollClipboard() }
        RunLoop.main.add(poll, forMode: .common); clipboardTimer = poll
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
            controller.onControlPermission = { [weak self] in self?.allowKeyboardAndMouse() }
            controller.onAutomaticChange = { [weak self] enabled in self?.setSharingAutomatically(enabled) }
            controller.onDiagnostics = { [weak self] in self?.saveDiagnostics(self?.lastHostMeasurements) }
            controller.onClipboardChange = { [weak self] enabled in self?.sharesClipboard = enabled }
        }
        refreshShare()
        shareWindow?.showWindow(nil); shareWindow?.window?.center(); NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshShare(_ message: String? = nil) {
        shareWindow?.toggle.title = isSharing ? "Stop Sharing" : "Start Sharing"
        shareWindow?.copy.isEnabled = isSharing
        let idle = sharesAutomatically && !userStoppedSharing ? "Sharing paused · resumes automatically" : "Sharing is off"
        var connected = "Connected · sharing this display"
        if let viewer = hostPeerVersion, viewer != NativeVersion.local { connected += " · the viewer runs \(viewer.name)" }
        var ready = "Ready for your other Mac"
        if !NativePrivacyGuard.mayShareNow() || !NativePrivacyGuard.displayIsAwake {
            ready = "Ready for your other Mac · its connection wakes this display"
        }
        shareWindow?.status.stringValue = isSharing ? (hostChannel == nil ? ready : connected) : idle
        shareWindow?.control.isEnabled = !NativeInputInjector.isTrusted
        shareWindow?.control.title = NativeInputInjector.isTrusted ? "Keyboard & Mouse Enabled" : "Enable Keyboard & Mouse…"
        shareWindow?.automatic.state = sharesAutomatically ? .on : .off
        shareWindow?.clipboard.state = sharesClipboard ? .on : .off
        if let message { shareWindow?.detail.stringValue = message }
        onChange?()
    }

    /// Keyboard and mouse control needs Accessibility on this, the sharing, Mac.
    var keyboardAndMouseAllowed: Bool { NativeInputInjector.isTrusted }
    func allowKeyboardAndMouse() {
        AppleSession.requestPermission()
        shareWindow?.detail.stringValue = "Enable MacLink in macOS Accessibility to allow keyboard and mouse. Viewing works without it."
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    /// Turning it on starts sharing now; turning it off leaves a running share alone.
    func setSharingAutomatically(_ enabled: Bool) {
        sharesAutomatically = enabled
        NativeLog.session.notice("automatic sharing \(enabled ? "on" : "off", privacy: .public)")
        if enabled && !isSharing { userStoppedSharing = false; startSharing() } else { refreshShare() }
    }
    /// The paired Mac this Mac is viewing now, if any.
    var connectedPeerID: String? { isConnected ? viewerWindow?.peerID : nil }

    /// With automatic sharing, a sleeping display or a covered screen doesn't
    /// stop sharing: this Mac keeps listening, and an approved Mac's
    /// connection wakes it (wakeForViewer).
    private var listensWhileCovered: Bool { sharesAutomatically && !userStoppedSharing }
    /// Stop reasons say whether sharing comes back by itself.
    private func pausedReason(_ reason: String) -> String {
        sharesAutomatically && !userStoppedSharing
            ? reason + " Sharing resumes automatically when this Mac is awake and unlocked."
            : reason + " Start Sharing when ready."
    }

    private func capabilitiesAreReady() {
        capabilityGate.complete()
    }
    /// Runs `work` now, or once the launch self-tests finish. At most eight wait.
    private func whenCapabilitiesReady(token: NativeRunToken? = nil, _ work: @escaping () -> Void) -> Bool {
        switch capabilityGate.admit(token: token, work) {
        case .ready: return true
        case .waiting: return false
        case .rejected: token?.cancel(); return false
        }
    }

    /// Automatic starts never show a permission prompt; the first manual start asks once.
    private func startSharing(automatic: Bool = false) {
        guard !isSharing else { return }
        guard whenCapabilitiesReady({ [weak self] in
            guard let self, !self.userStoppedSharing else { return }
            self.startSharing(automatic: automatic)
        }) else { return }
        guard NativePrivacyGuard.mayShareNow() || (automatic && listensWhileCovered && NativePrivacyGuard.mayListenNow()) else {
            refreshShare("Unlock this Mac and sign in before starting sharing.")
            return
        }
        guard CGPreflightScreenCaptureAccess() || (!automatic && CGRequestScreenCaptureAccess()) else {
            refreshShare("Allow MacLink in macOS Screen Recording, then click Start Sharing again.")
            return
        }
        do {
            var identity: NativeHostIdentity
            if let saved = try keychain.hostIdentity() { try saved.validate(); identity = saved }
            else {
                // A new identity approves no Mac: clear any list left from an earlier one first.
                try deviceStore.reset()
                identity = try NativeHostIdentity.create(); try keychain.saveHostIdentity(identity)
            }
            // A Mac that shared before per-device keys keeps accepting its old
            // code, so its paired Macs can move over; a new identity never does.
            try deviceStore.prepare(acceptOldCode: identity.listsDevices != true)
            if identity.listsDevices != true {
                var marked = identity; marked.listsDevices = true
                do { try keychain.saveHostIdentity(marked); identity = marked }
                catch { NativeLog.session.error("couldn't note the approved-Mac list with this Mac's identity") }
            }
            let listener = try NativeTransport.listen(identity: identity, devices: deviceStore)
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
    /// Automatic sharing listens while the display sleeps or the screen is
    /// covered, as after an update installed then. A timed-out covered session
    /// resumes once it becomes eligible, even if the display is still asleep.
    private func resumeSharingIfAutomatic() {
        let afterUpdate = defaults.bool(forKey: Self.resumeAfterUpdateKey)
        let eligible = NativePrivacyGuard.mayShareNow()
        needsUnlock = ml_host_needs_unlock(needsUnlock ? 1 : 0, eligible ? 1 : 0) != 0
        let unlocked = NativePrivacyGuard.displayIsAwake && eligible
        let covered = listensWhileCovered && !needsUnlock && NativePrivacyGuard.mayListenNow()
        guard sharesAutomatically || afterUpdate, !userStoppedSharing, !isSharing, uptime >= nextAutomaticShare,
              unlocked || covered else { return }
        nextAutomaticShare = uptime + 5
        if afterUpdate { defaults.removeObject(forKey: Self.resumeAfterUpdateKey) }
        startSharing(automatic: true)
    }
    /// Just before an update installs and MacLink relaunches: stop taking
    /// connections, so a viewer waiting for the new version doesn't reach this
    /// one, and remember to share again if sharing was on.
    func prepareForUpdateInstall() {
        guard isSharing else { return }
        if !sharesAutomatically { defaults.set(true, forKey: Self.resumeAfterUpdateKey) }
        stopSharing(reason: "Installing an update. Sharing resumes when MacLink restarts.")
    }

    private func acceptNext(listener: NativeTransport, token: NativeRunToken) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while token.isActive {
                do {
                    guard let transport = try listener.accept() else { continue }
                    DispatchQueue.main.async {
                        guard let self, token.isActive, self.sharingToken === token, self.hostChannel == nil else { transport.close(); return }
                        // Removed, or the old code stopped, while it was connecting.
                        guard self.stillAllowed(transport) else {
                            transport.close()
                            NativeLog.session.notice("a connection was withdrawn before it started")
                            self.acceptNext(listener: listener, token: token)
                            return
                        }
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
        guard sharingToken.isActive else { transport.close(); return }
        guard NativePrivacyGuard.mayShareNow(), NativePrivacyGuard.displayIsAwake else {
            wakeForViewer(transport, sharingToken: sharingToken)
            return
        }
        let channel = NativeSessionChannel(transport)
        hostChannel = channel; lastHostMeasurements = channel.measurements
        retiredEncoderCounters = NativeEncoderCounters(); hostInputGate.invalidate()
        flowKbps = UInt32(hostTuning.bitrate / 1000); flowState = MLFlowState(); keyframeLastSecond = false; lastLinkKbps = 0; flowLimit.reset()
        let version = channel.transport.protocolVersion
        let proof = transport.peerDevice.map { $0.isEmpty ? "the old pairing code" : "an approved Mac" } ?? "closed"
        NativeLog.session.notice("host session started, protocol \(version), \(proof, privacy: .public)")
        refreshClipboardScope(includeCurrent: false)
        let injector = NativeInputInjector(); hostInjector = injector
        hostAudioGate = NativeAudioSendGate()
        hostActivity = hostActivity ?? ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
            reason: "A paired Mac is viewing this display")
        channel.onFailure = { [weak self, weak channel] reason in
            guard let self, let channel, self.hostChannel === channel else { return }
            self.endHost(reason: reason)
        }
        if version >= 5 {
            // The viewer's Hello says whether it decodes HEVC 4:4:4; it arrives
            // within a round trip. Without one, start with H.264.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak channel] in
                guard let self, let channel, self.hostChannel === channel, self.capture == nil else { return }
                self.startCapture(for: channel)
            }
        } else {
            startCapture(for: channel)
        }
        readHost(channel, injector: injector)
        refreshShare()
    }

    /// Starts screen capture for a connected viewer using the current tuning.
    private func startCapture(for channel: NativeSessionChannel) {
        // While the viewer controls this Mac its own pointer is the cursor; drawing
        // this Mac's pointer into the video as well would show two.
        let tuning = hostTuning
        let codec: NativeVideoCodec = hevc444Available
            && channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_HEVC_444) != 0 ? .hevc : .h264
        // Sound goes only to a viewer that announced it plays it.
        let audioGate = hostAudioGate
        let audioEncoder = audioAvailable && channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_AUDIO) != 0
            ? try? NativeAudioEncoder() : nil
        let capture = NativeCapture(maxPixelWidth: tuning.maxWidth, framesPerSecond: tuning.fps,
                                    showsCursor: !NativeInputInjector.isTrusted, bitrate: currentBitrate,
                                    keyframeSeconds: tuning.keyframeSeconds, inFlightLimit: tuning.inFlight, codec: codec,
                                    capturesAudio: audioEncoder != nil && audioGate != nil)
        let firstKeyframe = NativeRunToken()
        let live = NativeRunToken()
        // Start a frame only while little video waits in the kernel, where a
        // newer frame can't replace it; the newest frame waits here instead.
        let limit = flowLimit
        capture.admitsFrame = { [weak channel] in
            guard let channel, let queue = channel.transport.sendQueue() else { return true }
            channel.measurements.recordMax("send_queue_bytes", Double(queue.queued_bytes))
            limit.sample(queue)
            return ml_flow_admits_frame(queue.queued_bytes, limit.bytes) != 0
        }
        if let audioEncoder, let audioGate {
            let firstSound = NativeRunToken()
            audioEncoder.onPacket = { [weak channel] payload in
                guard live.isActive, let channel, channel.token.isActive else { return }
                guard let sequence = audioGate.admit() else { channel.measurements.add("audio_dropped_packets"); return }
                if firstSound.cancel() { NativeLog.session.notice("streaming sound as Opus") }
                let packet = NativeAudioPacket(sequence: sequence, frames: UInt16(NativeAudioFormat.packetFrames), channels: 2, payload: payload)
                channel.measurements.add("sent_audio_packets"); channel.measurements.add("sent_audio_bytes", Double(payload.count))
                channel.send(.audio(packet), completion: audioGate.finished)
            }
            // The encoder is used only on the capture's audio queue.
            capture.onAudio = { sampleBuffer in if live.isActive { audioEncoder.append(sampleBuffer) } }
        }
        captureToken?.cancel(); captureToken = live
        self.capture = capture; captureMaxWidth = tuning.maxWidth
        capture.onGeometry = { [weak self, weak channel] geometry in
            guard let self, let channel, live.isActive, channel.token.isActive else { return }
            self.hostGeometryLock.lock(); self.hostGeometry = geometry; self.hostGeometryLock.unlock()
            channel.measurements.set("capture_pixel_width", Double(geometry.pixelWidth))
            channel.measurements.set("capture_pixel_height", Double(geometry.pixelHeight))
            channel.control(.geometry(geometry, inputEnabled: NativeInputInjector.isTrusted))
        }
        capture.onCapturedFrame = { [weak channel] delay in
            guard live.isActive, let channel else { return }
            channel.measurements.add("captured_frames"); channel.measurements.add("capture_ms_total", delay)
        }
        capture.onEncodedFrame = { [weak channel] frame, release in
            guard live.isActive, let channel, channel.token.isActive else { release(); return }
            // Per-frame values accumulate across capture restarts; the encoder's
            // own counters are sampled once a second.
            let measurements = channel.measurements
            measurements.set("last_encode_ms", frame.metrics.encode_ms)
            measurements.add("encoded_frames"); measurements.add("encode_ms_total", frame.metrics.encode_ms)
            measurements.recordMax("encode_ms", frame.metrics.encode_ms)
            if frame.keyframe { measurements.add("encoded_keyframes") }
            if frame.keyframe && firstKeyframe.cancel() {
                let chroma = frame.packet.chromaFormat.map { $0 == 3 ? ", 4:4:4 chroma confirmed" : ", chroma format \($0)" } ?? ""
                NativeLog.session.notice("streaming \(frame.packet.codec.name, privacy: .public) at \(frame.packet.width)×\(frame.packet.height)\(chroma, privacy: .public)")
            }
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
        // A new main display, such as the viewer-sized one, restarts capture on
        // it and sends the viewer fresh geometry instead of ending the session.
        capture.onDisplayChanged = { [weak self, weak channel] in
            DispatchQueue.main.async {
                guard let self, let channel, live.isActive, self.hostChannel === channel else { return }
                self.restartCaptureForDisplayChange(channel)
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
            NativeLog.session.notice("tuning: \(tuning.bitrate / 1000) kbps, width \(tuning.maxWidth), \(tuning.fps) fps, in flight \(tuning.inFlight), keyframe \(tuning.keyframeSeconds == 0 ? "when needed" : "every \(tuning.keyframeSeconds) s", privacy: .public)")
        }
        guard let channel = hostChannel, channel.token.isActive, let capture else { return }
        if tuning.maxWidth != captureMaxWidth { scheduleCaptureRestart() }
        if tuning.bitrate != previous.bitrate {
            // A new tuned bitrate is the new ceiling; pacing starts from it.
            flowKbps = UInt32(tuning.bitrate / 1000); flowState = MLFlowState(); keyframeLastSecond = false
            capture.setTargetBitrate(tuning.bitrate)
        }
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

    /// Restarts are spaced and bounded: six in 30 s, or the session ends.
    private func restartCaptureForDisplayChange(_ channel: NativeSessionChannel) {
        guard !displayRestartScheduled else { return }
        let now = uptime
        displayRestarts = displayRestarts.filter { now - $0 < 30 } + [now]
        guard displayRestarts.count <= 6 else {
            channel.fail("This Mac's display kept changing. Reconnect when it is settled.")
            return
        }
        displayRestartScheduled = true
        // No input lands on a display whose geometry the viewer has not seen.
        pauseCaptureForDisplayChange()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak channel] in
            guard let self else { return }
            self.displayRestartScheduled = false
            guard let channel, self.hostChannel === channel, channel.token.isActive, self.capture == nil else { return }
            NativeLog.session.notice("display changed; capturing the new main display")
            self.startCapture(for: channel)
        }
    }

    /// Retires capture and holds input until the viewer has the new geometry.
    /// Whoever paused resumes capture; if nothing has after 5 s, this does.
    private func pauseCaptureForDisplayChange() {
        retireCapture()
        hostGeometryLock.lock(); hostGeometry = nil; hostGeometryLock.unlock()
        hostInjector?.releaseAll()
        guard let channel = hostChannel else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak channel] in
            guard let self, let channel, self.hostChannel === channel, channel.token.isActive, self.capture == nil else { return }
            NativeLog.session.notice("display change did not finish; capturing the current main display")
            self.startCapture(for: channel)
        }
    }

    /// The viewer's latest request wins; it applies after half a second of quiet.
    private func requestDisplay(width: Int, height: Int, scale: Int, channel: NativeSessionChannel) {
        pendingDisplayRequest = (width, height, scale)
        guard !displayRequestScheduled else { return }
        displayRequestScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak channel] in
            guard let self else { return }
            self.displayRequestScheduled = false
            guard let channel, self.hostChannel === channel, channel.token.isActive, let request = self.pendingDisplayRequest else { return }
            self.pendingDisplayRequest = nil
            guard self.sharedDisplay.changes(width: request.width, height: request.height, scale: request.scale) else { return }
            // Stop capture before the display changes, rather than wait for
            // ScreenCaptureKit to fail, and capture whichever display is in
            // use once macOS has it ready.
            self.pauseCaptureForDisplayChange()
            self.sharedDisplay.apply(width: request.width, height: request.height, scale: request.scale) { [weak self, weak channel] applied in
                guard let self else { return }
                if request.width == 0 {
                    NativeLog.session.notice("sharing this Mac's own display again")
                } else {
                    NativeLog.session.notice("viewer-sized display \(request.width)×\(request.height) points at \(request.scale)x: \(applied ? "active" : "refused, sharing this Mac's own display", privacy: .public)")
                }
                guard let channel, self.hostChannel === channel, channel.token.isActive, self.capture == nil else { return }
                self.startCapture(for: channel)
            }
        }
    }

    private func updateHostPermission() {
        guard NativePrivacyGuard.mayShareNow() else {
            // While covered, an approved Mac's connection is waking it, or nothing is connected.
            if hostChannel != nil || !listensWhileCovered || !NativePrivacyGuard.mayListenNow() {
                pauseSharing("This Mac is no longer active.")
            }
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
                            DispatchQueue.main.async { [weak self, weak channel] in
                                guard let self, let channel, self.hostChannel === channel else { return }
                                self.pauseSharing("This Mac is no longer active.")
                            }
                            return
                        }
                        self.hostGeometryLock.lock(); let geometry = self.hostGeometry; self.hostGeometryLock.unlock()
                        guard channel.token.isActive, allowed.trusted, let g = geometry else { injector.releaseAll(); continue }
                        try injector.apply(event, displayBounds: CGRect(x: g.x, y: g.y, width: g.width, height: g.height))
                    case .control(.ping(let id)):
                        // A viewer that measures latency also gets this Mac's clock.
                        if channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_LATENCY) != 0 {
                            channel.control(.clock(id, hostUs: NativeClock.nowUs))
                        } else {
                            channel.control(.pong(id))
                        }
                    case .control(.keyframe):
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel else { return }
                            self.capture?.requestKeyframe()
                        }
                    case .control(.displayRequest(let width, let height, let scale)):
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel else { return }
                            self.requestDisplay(width: width, height: height, scale: scale, channel: channel)
                        }
                    case .control(.hello(let capabilities)):
                        // Rust has recorded the viewer's capabilities; start with the best shared codec.
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel else { return }
                            if capabilities & UInt64(ML_CAPABILITY_CURSOR) != 0 { self.cursorWatcher.start(); self.cursorWatcher.resend() }
                            if capabilities & UInt64(ML_CAPABILITY_VERSION) != 0 { channel.control(.version(.local)) }
                            if self.capture == nil { self.startCapture(for: channel) }
                        }
                    case .control(.version(let version)):
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel else { return }
                            self.hostPeerVersion = version
                            NativeLog.session.notice("viewer runs MacLink \(version.name, privacy: .public) (build \(version.build))")
                            self.refreshShare()
                        }
                    case .control(.updateRequest):
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel else { return }
                            NativeLog.updates.notice("the viewer asked this Mac to check for updates")
                            self.onUpdateRequest?()
                        }
                    case .telemetry(.stats(let stats)):
                        channel.storePeerStats(stats)
                    case .telemetry(.tuning(let tuning)):
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel else { return }
                            self.applyTuning(tuning)
                        }
                    case .clipboard(let content):
                        guard let scope = self.clipboard.scopeToken else { continue }
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel else { return }
                            self.applyClipboard(content, from: channel, within: scope)
                        }
                    case .control, .video, .cursor, .audio:
                        throw NativeSessionError(message: "The viewer sent an unexpected session message.")
                    }
                } catch { if channel.token.isActive { channel.fail(error.localizedDescription) }; return }
            }
        }
    }

    private func endHost(reason: String) {
        recordEnd("host", reason)
        hostChannel?.close(); hostChannel = nil; hostAudioGate = nil; hostPeerVersion = nil
        refreshClipboardScope(includeCurrent: false)
        cursorWatcher.stop()
        sharedDisplay.release(); pendingDisplayRequest = nil; displayRestarts = []
        endHostActivity()
        retireCapture(); hostInjector?.stop(); hostInjector = nil
        hostGeometryLock.lock(); hostGeometry = nil; hostGeometryLock.unlock()
        refreshShare(reason + " Waiting for a new connection.")
        if let listener, let token = sharingToken, token.isActive { acceptNext(listener: listener, token: token) }
    }
    /// This Mac's display slept, or its screen was covered or locked. A session
    /// ends at once: a covered screen is never shared. With automatic sharing
    /// this Mac keeps listening; otherwise sharing stops.
    private func pauseSharing(_ reason: String) {
        guard isSharing, listensWhileCovered, NativePrivacyGuard.mayListenNow() else {
            stopSharing(reason: pausedReason("Sharing stopped. " + reason)); return
        }
        let listening = reason + " Still listening: your other Mac's connection wakes it."
        if hostChannel != nil { endHost(reason: listening) } else { refreshShare(listening) }
    }
    /// An approved Mac connected while this Mac's display slept or its screen
    /// was covered. Declaring user activity, as Screen Sharing does, wakes the
    /// display and lifts a cover that needs no password; the session starts
    /// once this Mac may share. Rust bounds activity renewals and the wait.
    /// A screen still covered after the deadline waits for an unlock; an
    /// eligible session with a sleeping display keeps accepting connections.
    private func wakeForViewer(_ transport: NativeTransport, sharingToken: NativeRunToken) {
        guard sharingToken.isActive, self.sharingToken === sharingToken else { transport.close(); return }
        guard listensWhileCovered, NativePrivacyGuard.mayListenNow() else {
            transport.close()
            stopSharing(reason: pausedReason("Sharing stopped because this Mac is no longer active."))
            return
        }
        NativeLog.session.notice("an approved Mac connected while this display slept or was covered; waking it")
        let started = uptime
        checkWake(transport, sharingToken: sharingToken, started: started, activity: NativeWakeActivity(), state: MLHostWake())
    }
    private func checkWake(_ transport: NativeTransport, sharingToken: NativeRunToken, started: TimeInterval,
                           activity: NativeWakeActivity, state: MLHostWake) {
        guard sharingToken.isActive, self.sharingToken === sharingToken, hostChannel == nil else {
            transport.close(); activity.stop(); return
        }
        let elapsed = max(0, uptime - started)
        let eligible = NativePrivacyGuard.mayShareNow()
        var nextState = state
        let action = ml_host_wake_step(&nextState, UInt32(clamping: Int(min(elapsed * 1000, Double(UInt32.max)))),
                                      listensWhileCovered && NativePrivacyGuard.mayListenNow() ? 1 : 0,
                                      eligible ? 1 : 0, NativePrivacyGuard.displayIsAwake ? 1 : 0)
        switch Int(action) {
        case ML_HOST_WAKE_READY:
            NativeLog.session.notice("awake and unlocked \(Int(elapsed * 1000)) ms after waking for the approved Mac")
            // Removed, or the old code stopped, while it woke.
            guard stillAllowed(transport) else {
                transport.close(); activity.stop()
                if let listener { acceptNext(listener: listener, token: sharingToken) }
                return
            }
            beginHost(transport, sharingToken: sharingToken)
            activity.stop()
            return
        case ML_HOST_WAKE_DECLARE_ACTIVITY:
            let succeeded = activity.request()
            NativeLog.session.notice("remote wake activity \(nextState.attempts): \(succeeded ? "accepted" : "failed", privacy: .public)")
        case ML_HOST_WAKE_WAIT: break
        case ML_HOST_WAKE_TIMED_OUT:
            transport.close(); activity.stop()
            if eligible {
                needsUnlock = false
                refreshShare("This Mac's display didn't wake in time. Still listening for your paired Macs.")
                NativeLog.session.notice("wake timed out with an eligible session; still listening")
                if let listener { acceptNext(listener: listener, token: sharingToken) }
            } else {
                needsUnlock = true
                stopSharing(reason: "This Mac's screen is still covered or its session is unavailable after the wake attempt. "
                            + "Sharing resumes automatically once the session is unlocked and active.")
            }
            return
        default:
            transport.close(); activity.stop()
            stopSharing(reason: pausedReason("Sharing stopped because this Mac is no longer active."))
            return
        }
        let pendingState = nextState
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { transport.close(); activity.stop(); return }
            self.checkWake(transport, sharingToken: sharingToken, started: started, activity: activity, state: pendingState)
        }
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
        hostChannel?.close(); hostChannel = nil; hostAudioGate = nil; hostPeerVersion = nil
        refreshClipboardScope(includeCurrent: false)
        cursorWatcher.stop()
        sharedDisplay.release(); pendingDisplayRequest = nil; displayRestarts = []
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

    /// A one-time code: it approves one Mac within ten minutes while this
    /// listener runs, and a newer code replaces it.
    private func pairingCode() throws -> NativePairingCode {
        guard let identity = hostIdentity, let listener, isSharing else {
            throw NativeSessionError(message: "Start sharing before copying a pairing code.")
        }
        let localName = SCDynamicStoreCopyLocalHostName(nil) as String? ?? "localhost"
        return try NativePairingCode.forHost(address: localName + ".local", computerName: NativeDeviceKey.computerName, identity: identity,
                                             oneTimeSecret: listener.newPairingSecret(), alternates: NativePairingCode.localAddresses())
    }
    private func copyPairingCode() {
        do {
            let code = try pairingCode().encoded()
            // The code carries a one-time pairing secret. The nspasteboard.org
            // concealed marker asks clipboard managers not to record or display it.
            let item = NSPasteboardItem()
            item.setString(code, forType: .string)
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item])
            shareWindow?.detail.stringValue = "Pairing code copied. Paste it into Connect with MacLink on your other Mac within 10 minutes, "
                + "while sharing stays on. It pairs one Mac, once; copying another code replaces it."
        } catch { refreshShare(error.localizedDescription) }
    }
    private func resetPairing() {
        stopSharing(reason: "Pairing reset requested.")
        do {
            // Approvals first: if they can't be cleared, the old identity stays.
            try deviceStore.reset()
            let identity = try NativeHostIdentity.create(); try keychain.saveHostIdentity(identity); hostIdentity = identity
            refreshShare("No Mac can connect until it pairs again. Start sharing and copy a new code.")
        } catch { refreshShare(error.localizedDescription) }
    }

    /// Whether the Mac on `transport` may still connect: its key is still
    /// listed, or it used the old code and that still works.
    private func stillAllowed(_ transport: NativeTransport) -> Bool {
        guard let device = transport.peerDevice, let state = try? deviceStore.load() else { return false }
        return device.isEmpty ? state.legacy.isOpen : state.devices.contains { $0.id == device }
    }
    /// Macs approved to connect to this one, and whether the old code still works.
    func approvedDevices() -> (devices: [NativeDevice], legacy: NativeLegacyState)? { try? deviceStore.load() }
    /// The approved Mac viewing this one now; "" when it used the old code.
    var connectedDeviceID: String? { hostChannel?.transport.peerDevice }
    /// It can't connect again without a new code, and a live session ends now.
    func removeDevice(_ id: String) throws {
        try deviceStore.remove(id)
        NativeLog.session.notice("an approved Mac was removed")
        if let channel = hostChannel, channel.transport.peerDevice == id {
            endHost(reason: "The viewing Mac was removed in Settings.")
        }
        refreshShare()
    }
    /// The old pairing code stops now, and a Mac using it now is disconnected.
    func stopOldCode() throws {
        try deviceStore.stopOldCode()
        NativeLog.session.notice("the old pairing code was stopped")
        if let channel = hostChannel, channel.transport.peerDevice == "" {
            endHost(reason: "This Mac stopped accepting its old pairing code.")
        }
        refreshShare()
    }
    func extendOldCode() throws { try deviceStore.extendOldCode(); refreshShare() }

    func showConnect() {
        if let viewerWindow, isConnected { viewerWindow.showWindow(nil); NSApp.activate(ignoringOtherApps: true); return }
        if pairWindow == nil {
            let controller = NativePairWindow(); pairWindow = controller
            controller.onConnect = { [weak self] rawCode, override in
                guard let self else { return }
                do {
                    let code = try NativePairingCode.parse(rawCode)
                    // An address typed in is tried first, with every address in the code.
                    let address = override.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.connect(code: code, addresses: address.isEmpty ? code.addresses : [address] + code.addresses, pairing: true)
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
        resumeAfterWake = nil
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
            connect(code: code, addresses: peer.addresses, automatic: automatic)
        } catch { connectFailed(error, peerID: peerID) }
    }
    /// `automatic` attempts come from the reconnect budget: they never bring
    /// MacLink forward or take keyboard focus from another app.
    /// `addresses` are tried together, the first preferred.
    private func connect(code: NativePairingCode, addresses: [String], pairing: Bool = false, automatic: Bool = false) {
        guard !isConnected, !capabilityGate.isStopped else { return }
        if let current = connecting {
            // A new pairing takes over from automatic reconnecting; anything else waits.
            guard pairing, !current.pairing else { return }
            endReconnecting(reason: lastViewerEnd.isEmpty ? "Reconnecting stopped for a new pairing." : lastViewerEnd)
        }
        var candidates: [String] = []
        for entry in addresses {
            guard let address = NativePairingCode.normalizedAddress(entry) else {
                pairWindow?.error.stringValue = "Enter a hostname or IP address without a port."; return
            }
            if !candidates.contains(address) { candidates.append(address) }
        }
        let addresses = Array(candidates.prefix(Int(ML_ADDRESSES_MAX)))
        let attempt = NativeRunToken(), peerID = code.peerID
        connecting = (attempt, peerID, pairing)
        if pairing { pairWindow?.setBusy(true); pairWindow?.error.stringValue = "" }
        guard whenCapabilitiesReady(token: attempt, { [weak self] in
            self?.beginConnect(code: code, addresses: addresses, pairing: pairing, automatic: automatic, attempt: attempt)
        }) else {
            if !attempt.isActive, connecting?.token === attempt { cancelConnect() }
            return
        }
        beginConnect(code: code, addresses: addresses, pairing: pairing, automatic: automatic, attempt: attempt)
    }

    private func beginConnect(code: NativePairingCode, addresses: [String], pairing: Bool, automatic: Bool, attempt: NativeRunToken) {
        guard attempt.isActive, connecting?.token === attempt, !capabilityGate.isStopped else { return }
        let peerID = code.peerID
        let deviceKey: NativeDeviceKey
        do { deviceKey = try keychain.deviceKey() } catch {
            connecting = nil
            if pairing { pairWindow?.setBusy(false) }
            connectFailed(error, peerID: peerID, pairing: pairing); return
        }
        if let window = openViewerWindow(for: peerID) {
            window.status.stringValue = "Connecting…"
            if !window.isReconnecting { window.showConnecting() }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard attempt.isActive else { return }
            do {
                let (transport, mode, used) = try NativeTransport.connect(addresses: addresses, code: code, deviceKey: deviceKey)
                DispatchQueue.main.async {
                    guard let self, attempt.isActive, self.connecting?.token === attempt else { transport.close(); return }
                    self.connecting = nil
                    if pairing { self.pairWindow?.setBusy(false) }
                    // Which address, by position only: addresses are never logged.
                    let position = (addresses.firstIndex(of: used) ?? 0) + 1
                    NativeLog.session.notice("viewer connected with \(String(describing: mode), privacy: .public) by address \(position) of \(addresses.count)")
                    // Once the sharing Mac approved this Mac's key, the device
                    // pairing replaces the code: a one-time code is used up, and
                    // the old code stops a week after the first Mac moves over.
                    let saved = mode.approvedKey ? try? code.device() : code
                    guard pairing else {
                        if mode.approvedKey {
                            // The next connect moves over again if this can't be saved.
                            do {
                                guard let saved else { throw NativeSessionError(message: "Internal error") }
                                try self.keychain.savePeerCode(saved)
                            } catch { NativeLog.session.error("the device pairing couldn't be saved; the next connection moves over again") }
                        }
                        // The address that worked is tried first next time.
                        if (try? self.peerStore.connected(peerID, through: used)) != nil {
                            self.peers = (try? self.peerStore.load()) ?? self.peers
                        }
                        let peer = self.peers.first(where: { $0.id == peerID }) ?? NativePeer(code: code, address: used)
                        self.beginViewer(transport, peer: peer, activate: !automatic)
                        return
                    }
                    do {
                        guard let saved else { throw NativeSessionError(message: "Internal error") }
                        // Keychain is required to reconnect later. The menu list is a
                        // convenience: an unwritable peer file must not block this session.
                        try self.keychain.savePeerCode(saved)
                        let tried = [used] + addresses.filter { $0 != used }
                        let peer = (try? self.peerStore.remember(code, tried: tried)) ?? NativePeer(code: code, address: used)
                        self.peers = (try? self.peerStore.load()) ?? self.peers
                        self.pairWindow?.code.stringValue = ""; self.pairWindow?.close()
                        self.beginViewer(transport, peer: peer, activate: true, pairing: true)
                    } catch {
                        transport.close()
                        let used = mode == .pair ? " The code was used; copy a new one on the sharing Mac." : ""
                        self.connectFailed(NativeSessionError(message: error.localizedDescription + used), peerID: peerID, pairing: true)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, attempt.isActive, self.connecting?.token === attempt else { return }
                    self.connecting = nil
                    if pairing { self.pairWindow?.setBusy(false) }
                    self.connectFailed(error, peerID: peerID, pairing: pairing, kind: code.kind)
                }
            }
        }
    }
    /// Pairing reports in its form. A window already showing this Mac reports
    /// in place and retries within the budget; a first connect shows an alert.
    private func connectFailed(_ error: Error, peerID: String, pairing: Bool = false, kind: NativePairingCode.Kind? = nil) {
        var message = error.localizedDescription
        let refused = (error as? NativeSessionError)?.isAuthenticationFailure == true
        let notSharing = (error as? NativeSessionError)?.isNotSharing == true
        if notSharing {
            message = "The sharing Mac answered, but MacLink isn't sharing there right now. Its screen may be locked with a password: "
                + "unlock it, for example with Screen Sharing, and MacLink reconnects within seconds."
        }
        if refused && pairing {
            message = kind == .oneTime
                ? "The sharing Mac didn't accept this code. A code works once, on one Mac, within 10 minutes, and a newer code "
                    + "replaces it. Copy a new code on that Mac and try again."
                : "The sharing Mac no longer accepts this older code. Copy a new code on that Mac and try again."
        }
        // Different versions end the handshake without a reason on the other side.
        if [Int32(ML_SESSION_CLOSED), Int32(ML_SESSION_PROTOCOL)].contains((error as? NativeSessionError)?.status ?? 0) {
            message += " If the other Mac runs a different MacLink version, update both Macs."
            onVersionMismatch?()
        }
        if pairing {
            if pairWindow?.window?.isVisible == true { pairWindow?.error.stringValue = message } else { showError(message) }
            return
        }
        guard let window = openViewerWindow(for: peerID) else { showError(message); return }
        NativeLog.session.notice("viewer connect failed: \(message, privacy: .public)")
        window.status.stringValue = message
        if refused {
            stopReconnecting()
            window.showEnded(reason: "The sharing Mac no longer accepts this Mac: it was removed there, or its pairing was reset. "
                             + "Pair again with a new code from that Mac.")
            return
        }
        // Someone has to unlock it: keep trying every few seconds for a while.
        if notSharing && !awaitingPeer { awaitingPeer = true; reconnectAttempts = 0 }
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
        // While the sharing Mac installs an update, Rust's longer schedule.
        let milliseconds = awaitingPeer ? ml_update_reconnect_delay_ms(UInt32(attempt)) : ml_reconnect_delay_ms(UInt32(attempt))
        guard milliseconds >= 0 else { reconnectAttempts = 0; awaitingPeer = false; return false }
        reconnectAttempts = attempt
        window.showReconnecting(reason: reason, attempt: attempt,
                                of: Int(awaitingPeer ? ML_UPDATE_RECONNECT_ATTEMPTS : ML_RECONNECT_ATTEMPTS))
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
        reconnectWork?.cancel(); reconnectWork = nil; reconnectAttempts = 0; awaitingPeer = false
    }
    /// Stops reconnecting and any connect in flight; a window still saying
    /// "Reconnecting…" shows `reason` instead.
    private func endReconnecting(reason: String) {
        stopReconnecting(); cancelConnect()
        if viewerChannel == nil, let window = viewerWindow, !window.isClosed, window.isReconnecting { window.showEnded(reason: reason) }
    }

    /// `pairing`: the clipboard may still hold the code just pasted, so what is
    /// already copied is not shared for this first session.
    private func beginViewer(_ transport: NativeTransport, peer: NativePeer, activate: Bool, pairing: Bool = false) {
        let channel = NativeSessionChannel(transport), decoder = NativeVideoDecoder()
        viewerChannel = channel; self.decoder = decoder; lastViewerMeasurements = channel.measurements
        firstFrame = false; viewerInputEnabled = false; pendingPing = nil; lastPresented = 0; lastStatusTime = uptime
        clockSync.reset(); latencySecond = NativeLatencyWindow(); latencyReport = NativeLatencyWindow()
        drawReportTicks = 0; drawReportDecoded = 0
        observedScreenRequest = nil; sentScreenRequest = nil
        viewerStarted = uptime; reconnectWork?.cancel(); reconnectWork = nil
        // What is already copied here is available to paste on the other Mac.
        refreshClipboardScope(includeCurrent: !pairing)
        if sharesClipboard {
            NativeLog.session.notice("clipboard access: \(NativePasteboard.accessDescription(.general), privacy: .public)")
        }
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
            self.disconnectViewer(reason: "Disconnected.", leaving: true)
        }
        let release: () -> Void = { [weak self, weak channel] in
            guard let self, let channel, self.viewerChannel === channel else { return }
            self.releaseViewerInput()
        }
        window.onReleaseInput = release; window.video.onReleaseInput = release
        window.onDiagnostics = { [weak self, measurements = channel.measurements] in self?.saveDiagnostics(measurements) }
        window.onVersionAction = { [weak self] in self?.versionNoticeClicked() }
        viewerPeerVersion = nil; peerUpdate = nil; window.setVersionNotice(nil)
        if awaitingPeer {
            // The sharing Mac is back after its update.
            awaitingPeer = false; reconnectAttempts = 0
        }
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
        window.video.onFrameTiming = { [weak self, weak channel] timing in
            guard let self, let channel, self.viewerChannel === channel, let latency = self.clockSync.latency(timing) else { return }
            self.latencySecond.add(latency); self.latencyReport.add(latency)
        }
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
        audioPlayer?.stop(); audioPlayer = NativeAudioPlayer(muted: !playsSound); audioReported = NativeAudioStats()
        window.video.waitsForDisplayRefresh = !lowersDisplayLatency
        readViewer(channel, decoder: decoder)
        onChange?()
    }

    /// Rust admits only video, geometry, input state and pong here, requires
    /// geometry before video, limits control rate, and ends an idle session.
    private func readViewer(_ channel: NativeSessionChannel, decoder: NativeVideoDecoder) {
        let player = audioPlayer
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
                    case .clipboard(let content):
                        guard let scope = self.clipboard.scopeToken else { continue }
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.viewerChannel === channel else { return }
                            self.applyClipboard(content, from: channel, within: scope)
                        }
                    case .cursor(let image):
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.viewerChannel === channel else { return }
                            self.viewerWindow?.video.remoteCursor = image.cursor
                        }
                    case .audio(let packet):
                        player?.receive(packet)
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
        case .clock(let id, let hostUs):
            let received = NativeClock.nowUs
            if let outstanding = pendingPing, id == outstanding.0 {
                channel.measurements.set("network_round_trip_ms", (uptime - outstanding.1) * 1000)
                clockSync.add(sentUs: NativeClock.microseconds(outstanding.1), receivedUs: received, hostUs: hostUs)
                if let estimate = clockSync.estimate { channel.measurements.set("clock_error_ms", Double(estimate.errorUs) / 1000) }
                pendingPing = nil
            }
        case .hello(let capabilities):
            if capabilities & UInt64(ML_CAPABILITY_VERSION) != 0 { channel.control(.version(.local)) }
        case .version(let version):
            viewerPeerVersion = version
            NativeLog.session.notice("sharing Mac runs MacLink \(version.name, privacy: .public) (build \(version.build))")
            refreshVersionNotice()
        case .updateStatus(let state, let ready):
            peerUpdate = (state, ready, uptime)
            NativeLog.updates.notice("sharing Mac update check: \(String(describing: state), privacy: .public)")
            refreshVersionNotice()
        case .ping, .keyframe, .displayRequest, .updateRequest, .leaving:
            break
        }
    }
    /// Host: tells the connected viewer how its requested update check went.
    func reportUpdateStatus(_ state: NativeUpdateState, ready: NativeVersion?) {
        guard let channel = hostChannel, channel.token.isActive,
              channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_VERSION) != 0 else { return }
        if state == .ready { viewerAwaitsInstall = true }
        channel.control(.updateStatus(state, ready: ready))
    }
    /// Viewer: what the versions mean for the person in front of this Mac.
    private func refreshVersionNotice() {
        guard let window = viewerWindow else { return }
        guard let peer = viewerPeerVersion, let channel = viewerChannel, channel.token.isActive else {
            window.setVersionNotice(nil); return
        }
        let local = NativeVersion.local
        window.status.toolTip = "The sharing Mac runs MacLink \(peer.name); this Mac runs \(local.name)."
        switch local.compared(to: peer) {
        case .orderedDescending:
            guard channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_REMOTE_UPDATE) != 0 else {
                window.setVersionNotice("Sharing Mac runs \(peer.name); update it there", enabled: false); return
            }
            switch peerUpdate {
            case nil:
                window.setVersionNotice("Sharing Mac runs \(peer.name) · Update It", enabled: true)
            case .some((.checking, _, _)):
                window.setVersionNotice("Sharing Mac is checking for updates…", enabled: false)
            case .some((.ready, let ready, _)):
                window.setVersionNotice("\(ready?.name ?? "An update") is ready on the sharing Mac · Disconnect and Update", enabled: true)
            case .some((.upToDate, _, let at)), .some((.failed, _, let at)):
                // The sharing Mac takes another request a minute later.
                let wait = max(0, 61 - (uptime - at))
                let reason = peerUpdate?.state == .upToDate ? "found no newer update yet" : "couldn't check for updates"
                window.setVersionNotice("Sharing Mac \(reason)\(wait > 0 ? "" : " · Try Again")", enabled: wait == 0)
                if wait > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.refreshVersionNotice() }
                }
            }
        case .orderedAscending:
            window.setVersionNotice("This Mac runs \(local.name), the sharing Mac \(peer.name) · Check for Updates", enabled: true)
        case .orderedSame, nil:
            window.setVersionNotice(nil)
        }
    }
    private func versionNoticeClicked() {
        guard let peer = viewerPeerVersion, let channel = viewerChannel, channel.token.isActive else { return }
        switch NativeVersion.local.compared(to: peer) {
        case .orderedAscending:
            onCheckForUpdates?()
        case .orderedDescending:
            if case .some((.ready, let ready, _)) = peerUpdate {
                awaitingPeer = true; reconnectAttempts = 0
                NativeLog.updates.notice("disconnecting so the sharing Mac can install \(ready?.name ?? "its update", privacy: .public)")
                disconnectViewer(reason: "The sharing Mac is installing \(ready?.name ?? "an update") and will restart. MacLink reconnects when it's back.",
                                 reconnect: true)
            } else {
                peerUpdate = (.checking, nil, uptime)
                updateRequestSerial += 1
                let serial = updateRequestSerial
                channel.control(.updateRequest)
                refreshVersionNotice()
                // A check that never answers, as when the sharing Mac shows an
                // update window, may be asked again after 90 s.
                DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
                    guard let self, self.updateRequestSerial == serial, self.peerUpdate?.state == .checking else { return }
                    self.peerUpdate = (.failed, nil, self.uptime - 61)
                    self.refreshVersionNotice()
                }
            }
        default:
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
        // Rust refuses gestures to a host that did not announce it injects them.
        if input.kind.isGesture, channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_GESTURES) == 0 { return }
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
        drawReportTicks += 1
        if drawReportTicks >= 10, let video = viewerWindow?.video {
            drawReportTicks = 0
            let decoded = snapshot["decoded_frames", default: 0], draw = video.takeDrawStats()
            if draw.drawn > 0 || draw.busy > 0 {
                NativeLog.session.notice("viewer drawing, last 10 s: \(Int(decoded - self.drawReportDecoded)) decoded, \(draw.summary, privacy: .public)")
            }
            drawReportDecoded = decoded
            if let latency = latencyReport.summary, let clock = clockSync.estimate {
                NativeLog.session.notice("viewer latency, last 10 s: \(self.latencyReport.totals.count) frames, median \(Int(latency.p50.rounded())) ms, 95th percentile \(Int(latency.p95.rounded())) ms; median \(Int(latency.toViewer.rounded())) ms until decoding starts, \(Int(latency.displayWait.rounded())) ms from decoded to shown; clocks within \(Int((Double(clock.errorUs) / 1000).rounded(.up))) ms")
            }
            latencyReport = NativeLatencyWindow()
            if let player = audioPlayer {
                let sound = player.snapshot(), previous = audioReported
                audioReported = sound
                let received = sound.packets - previous.packets
                channel.measurements.set("received_audio_packets", Double(sound.packets))
                channel.measurements.set("audio_underruns", Double(sound.underruns))
                channel.measurements.set("audio_gap_packets", Double(sound.gaps))
                if received > 0 {
                    NativeLog.session.notice("viewer sound, last 10 s: \(received) packets, \(sound.gaps - previous.gaps) missing, \(sound.droppedPackets - previous.droppedPackets) dropped waiting, \(sound.underruns - previous.underruns) ran dry, \((sound.droppedFrames - previous.droppedFrames) / 48) ms trimmed, \(sound.bufferedFrames / 48) ms buffered")
                }
            }
        }
        let latency = latencySecond.summary
        latencySecond = NativeLatencyWindow()
        if let latency {
            channel.measurements.set("latency_ms", latency.p50); channel.measurements.set("latency_ms_p95", latency.p95)
            channel.measurements.set("to_viewer_ms", latency.toViewer); channel.measurements.set("display_wait_ms", latency.displayWait)
        } else {
            // No frame reached the screen this second, as while the window is
            // hidden or the picture is still: report nothing rather than old figures.
            for key in ["latency_ms", "latency_ms_p95", "to_viewer_ms", "display_wait_ms"] { channel.measurements.remove(key) }
        }
        // Screen change on the sharing Mac to this display, when frames are
        // flowing and the clocks are placed; otherwise the network round trip.
        let rtt = latency.map { String(format: "%.0f ms latency", $0.p50) }
            ?? snapshot["network_round_trip_ms"].map { String(format: "%.0f ms RTT", $0) } ?? "checking connection"
        // The sharing Mac sends frames only when its screen changes, so the rate
        // follows activity there; it is not a cap.
        let rate = fps < 0.5 ? "screen unchanged" : String(format: "%.0f fps as the screen changes", fps)
        let size = viewerWindow?.video.geometry.map { " · \($0.pixelWidth)×\($0.pixelHeight)" } ?? ""
        viewerWindow?.status.stringValue = "\(viewerInputEnabled ? "Connected" : "View only") · \(rate) · \(rtt)\(size)"
        requestMatchingScreen(channel)
        if let pendingPing, now - pendingPing.1 > 8 { channel.fail("The sharing Mac stopped answering connection checks."); return }
        if pendingPing == nil {
            pingSequence &+= 1; pendingPing = (pingSequence, now)
            channel.control(.ping(pingSequence))
        }
    }
    /// Once a second: when the video area has kept the same size for a tick,
    /// ask a capable sharing Mac for a display exactly that size at this Mac's
    /// Retina scale, so the picture fills the window pixel for pixel.
    private func requestMatchingScreen(_ channel: NativeSessionChannel) {
        guard firstFrame, channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_VIRTUAL_DISPLAY) != 0,
              let view = viewerWindow?.video, let window = view.window else { return }
        var desired: (width: Int, height: Int, scale: Int) = (0, 0, 0)
        if matchesScreen {
            let scale = window.backingScaleFactor >= 2 ? 2 : 1
            var width = Double(view.bounds.width), height = Double(view.bounds.height)
            // Stay within the video limits (3840×2160 pixels), keeping the shape.
            let fit = min(1, 3840 / (width * Double(scale)), 2160 / (height * Double(scale)))
            width = (width * fit / 2).rounded(.down) * 2; height = (height * fit / 2).rounded(.down) * 2
            if width >= 320 && height >= 240 { desired = (Int(width), Int(height), scale) }
        }
        defer { observedScreenRequest = desired }
        guard let observed = observedScreenRequest, observed == desired else { return }
        if let sent = sentScreenRequest, sent == desired { return }
        if sentScreenRequest == nil && desired.width == 0 { return }
        sentScreenRequest = desired
        channel.control(.displayRequest(width: desired.width, height: desired.height, scale: desired.scale))
        NativeLog.session.notice("asked the sharing Mac for a \(desired.width)×\(desired.height)-point display at \(desired.scale)x")
    }
    /// This Mac is going to sleep or locked. A session, or reconnecting, ends
    /// now, without telling the sharing Mac it's leaving, so it waits; this
    /// Mac reconnects once it's awake and unlocked.
    private func pauseViewer(reason: String) {
        let peerID = viewerWindow.flatMap { window in
            !window.isClosed && (viewerChannel != nil || connecting != nil || window.isReconnecting) ? window.peerID : nil
        }
        disconnectViewer(reason: peerID == nil ? reason + " Reconnect when ready." : reason + " MacLink reconnects when this Mac is awake and unlocked.")
        if let peerID { resumeAfterWake = peerID; NativeLog.session.notice("viewer paused; it reconnects after this Mac wakes") }
    }
    /// Runs once a second: reconnects a session this Mac's sleep or lock
    /// ended, once it's awake and unlocked, with a fresh reconnect budget.
    private func resumeViewerAfterWake() {
        guard let peerID = resumeAfterWake else { return }
        guard openViewerWindow(for: peerID) != nil else { resumeAfterWake = nil; return }
        guard !isConnected, connecting == nil, NativePrivacyGuard.mayShareNow(), NativePrivacyGuard.displayIsAwake else { return }
        resumeAfterWake = nil
        NativeLog.session.notice("this Mac is awake and unlocked; reconnecting the paused viewer")
        stopReconnecting()
        startConnect(peerID: peerID, automatic: true)
    }
    /// `reconnect` is set only for an unexpected end. Privacy, sleep, quitting
    /// and closing the window end any reconnecting instead. `leaving`: the
    /// user ended it, so a sharing Mac that waits for dropped viewers is told.
    func disconnectViewer(reason: String, reconnect: Bool = false, leaving: Bool = false) {
        if !reconnect { endReconnecting(reason: reason) }
        if leaving { resumeAfterWake = nil }
        // Privacy and sleep events call this with no session; leave any window
        // from an earlier session showing its own reason.
        guard let channel = viewerChannel else { return }
        let lasted = uptime - viewerStarted
        recordEnd("viewer", reason); lastViewerEnd = reason
        releaseViewerInput()
        if leaving && channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_WAITS) != 0 {
            channel.close(after: .control(.leaving))
        } else {
            channel.close()
        }
        viewerChannel = nil
        refreshClipboardScope(includeCurrent: false)
        viewerPeerVersion = nil; peerUpdate = nil; viewerWindow?.setVersionNotice(nil)
        audioPlayer?.stop(); audioPlayer = nil
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
        viewerWindow?.video.remoteCursor = nil
        if reconnect, let window = viewerWindow, !window.isClosed {
            // A session that stayed up starts a fresh budget, so rare drops never exhaust it.
            if lasted >= Double(ML_RECONNECT_STABLE_SECONDS) { reconnectAttempts = 0 }
            if !scheduleReconnect(window, reason: reason) { window.showEnded(reason: reason) }
        } else {
            viewerWindow?.showEnded(reason: reason)
        }
        onChange?()
    }

    private func pollClipboard() {
        guard sharesClipboard, isConnected || hostChannel?.token.isActive == true else { return }
        clipboard.poll()
    }
    /// A new scope captures these recipients. A delayed copy can never select
    /// a replacement channel or survive disconnect/disable/re-enable.
    private func refreshClipboardScope(includeCurrent: Bool) {
        clipboard.stop()
        guard sharesClipboard, !capabilityGate.isStopped, isConnected || hostChannel?.token.isActive == true else { return }
        clipboard.onSend = { [weak self, weak viewer = viewerChannel, weak host = hostChannel] content, scope in
            self?.sendClipboard(content, to: [viewer, host].compactMap { $0 }, within: scope)
        }
        clipboard.start(includeCurrent: includeCurrent)
    }
    private func sendClipboard(_ content: NativeClipboardContent, to recipients: [NativeSessionChannel], within scope: NativeRunToken) {
        guard sharesClipboard, scope.isActive else { return }
        var sent = false
        for channel in recipients where channel.token.isActive {
            channel.send(.clipboard(content), whileActive: scope)
            channel.measurements.add("clipboard_sent"); channel.measurements.add("clipboard_sent_bytes", Double(content.byteCount))
            sent = true
        }
        if sent { NativeLog.session.notice("clipboard sent: \(content.summary, privacy: .public)") }
    }
    private func applyClipboard(_ content: NativeClipboardContent, from channel: NativeSessionChannel, within scope: NativeRunToken) {
        guard sharesClipboard, scope.isActive else { return }
        clipboard.apply(content, from: channel.token, within: scope)
        channel.measurements.add("clipboard_received"); channel.measurements.add("clipboard_received_bytes", Double(content.byteCount))
        NativeLog.session.notice("clipboard received: \(content.summary, privacy: .public)")
    }

    /// Once a second: resume automatic sharing, exchange stats with the
    /// connected Mac, apply or forward local tuning commands, and publish a
    /// snapshot on the local socket.
    private func telemetryTick() {
        resumeSharingIfAutomatic()
        resumeViewerAfterWake()
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
                channel.measurements.set("queue_wait_ms", totals.queueWaitMs)
            }
            let interval = channel.measurements.nextInterval()
            if role == Int(ML_ROLE_HOST) { pace(interval) }
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
    /// The effective bitrate: the tuned one, or less while pacing has lowered it.
    private var currentBitrate: Int {
        flowKbps > 0 ? min(hostTuning.bitrate, Int(flowKbps) * 1000) : hostTuning.bitrate
    }
    /// Host, once a second: Rust lowers the bitrate when frames keep waiting
    /// for the send buffer and raises it again after clear seconds.
    private func pace(_ interval: NativeInterval) {
        guard let capture, let channel = hostChannel else { return }
        if let queue = channel.transport.sendQueue() { flowLimit.update(queue) }
        var kbps: UInt32 = 0
        let waited = UInt32(min(interval.delta("queue_wait_ms"), Double(UInt32.max)))
        let queued = UInt32(min(interval.maxima["send_queue_bytes"] ?? 0, Double(UInt32.max)))
        // An on-demand keyframe's drain, this second or spilling from the last,
        // isn't a slow connection. Periodic keyframes, when tuned, still count.
        let keyframe = interval.delta("encoded_keyframes") > 0
        let afterKeyframe = hostTuning.keyframeSeconds == 0 && (keyframe || keyframeLastSecond)
        keyframeLastSecond = keyframe
        // What the link carried while video waited for it: where a cut goes.
        // What was sent keeps a stall from passing for a slow link.
        let link = flowLimit.takeLinkKbps()
        lastLinkKbps = link
        let sent = UInt32(min(max(interval.rate("sent_video_bytes") * 8 / 1000, 0), Double(UInt32.max)))
        guard ml_flow_next_bitrate(flowKbps, UInt32(hostTuning.bitrate / 1000), waited, afterKeyframe ? 1 : 0, link, sent,
                                   &flowState, &kbps) == ML_SESSION_OK else { return }
        let previous = flowKbps
        flowKbps = kbps
        guard kbps != previous else { return }
        capture.setTargetBitrate(Int(kbps) * 1000)
        if kbps < previous {
            let carried = link > 0 ? "; the link carried \(Int(link)) kbps" : ""
            NativeLog.session.notice("pacing: frames waited \(Int(waited)) ms for the network, up to \(Int(queued / 1024)) KiB queued\(carried, privacy: .public); bitrate \(Int(kbps)) kbps")
        } else if kbps == UInt32(hostTuning.bitrate / 1000) {
            NativeLog.session.notice("pacing: connection clear; bitrate back to \(Int(kbps)) kbps")
        }
    }
    private func hostStats(_ interval: NativeInterval) -> NativeStats {
        var stats: NativeStats = [
            .captureFps: interval.rate("captured_frames"), .encodedFps: interval.rate("encoded_frames"),
            .skippedFps: interval.rate("skipped_capture_frames"), .droppedFps: interval.rate("encoder_dropped_frames"),
            .failedFrames: interval.delta("encoder_failed_frames"), .keyframes: interval.delta("encoded_keyframes"),
            .sentMbps: interval.rate("sent_video_bytes") * 8 / 1_000_000, .inFlight: Double(capture?.inFlightCount ?? 0),
            .bitrateMbps: Double(currentBitrate) / 1_000_000, .fpsCap: Double(hostTuning.fps),
            .queueWaitMs: interval.delta("queue_wait_ms"), .sendQueueKib: (interval.maxima["send_queue_bytes"] ?? 0) / 1024,
            .encodeMsMax: interval.maxima["encode_ms"] ?? 0, .sendMsMax: interval.maxima["video_send_ms"] ?? 0
        ]
        stats[.encodeMs] = interval.average("encode_ms_total", per: "encoded_frames")
        stats[.sendMs] = interval.average("video_send_ms_total", per: "sent_video_frames")
        stats[.frameKib] = interval.average("sent_video_bytes", per: "sent_video_frames").map { $0 / 1024 }
        stats[.pixelWidth] = interval.values["capture_pixel_width"]
        stats[.pixelHeight] = interval.values["capture_pixel_height"]
        stats[.captureMs] = interval.average("capture_ms_total", per: "captured_frames")
        if lastLinkKbps > 0 { stats[.linkMbps] = Double(lastLinkKbps) / 1000 }
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
        stats[.latencyMs] = interval.values["latency_ms"]
        stats[.latencyMsP95] = interval.values["latency_ms_p95"]
        stats[.toViewerMs] = interval.values["to_viewer_ms"]
        stats[.displayWaitMs] = interval.values["display_wait_ms"]
        stats[.clockErrorMs] = interval.values["clock_error_ms"]
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
        capabilityGate.stop()
        clipboard.stop()
        telemetryTimer?.invalidate(); telemetryTimer = nil
        clipboardTimer?.invalidate(); clipboardTimer = nil
        NativeTelemetryServer.stop()
        stopSharing(); disconnectViewer(reason: "MacLink stopped.", leaving: true)
        systemKeys?.stop(); systemKeys = nil
        privacyGuard?.stop(); privacyGuard = nil
        observerTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observerTokens.removeAll()
    }
}
