import AppKit
import IOKit.pwr_mgt
import ApplicationServices
import SystemConfiguration
import CoreVideo
import CryptoKit

/// Host input checks run on the network thread for every event. Session
/// eligibility and permission are re-read at most every 250 ms rather than per
/// event; lock and sleep notifications still end the session at once.
final class NativeHostInputGate: @unchecked Sendable {
    let lock = NSLock()
    var checked: TimeInterval?
    var state = (eligible: false, trusted: false)
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
struct NativeEncoderCounters {
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
    static let automaticSharingKey = "native.shareAutomatically"
    static let sharedClipboardKey = "native.shareClipboard"
    static let matchScreenKey = "native.matchScreen"
    static let besideCameraKey = "native.extendBesideCamera"
    static let playSoundKey = "native.playSound"
    static let lowLatencyDisplayKey = "native.lowLatencyDisplay"
    static let diagnosticBarKey = "native.showDiagnosticBar"
    /// One-shot: sharing was on, but not automatic, when a viewer's requested
    /// update installed; share again after the relaunch.
    static let resumeAfterUpdateKey = "native.resumeSharingAfterUpdate"
    /// Previews 28 saved a wait for a dropped viewer here; launch removes it.
    static let oldWaitForViewerKey = "native.waitForViewerUntil"
    let defaults: UserDefaults
    let keychain: any NativeCredentialVault
    let peerStore: any NativePeerRepository
    /// Macs approved to connect to this one.
    let deviceStore: any NativeDeviceRepository
    var shareWindow: NativeShareWindow?
    var pairWindow: NativePairWindow?
    /// Host: the PIN on screen, its pairing listener and Bonjour advert. The
    /// listener runs while the window is open, whether or not this Mac shares.
    var pinWindow: NativePinWindow?
    var pinListener: NativeTransport?
    var pinToken: NativeRunToken?
    var pinAdvert: NativePinAdvert?
    var pinTimer: Timer?
    /// Viewer: Macs nearby showing a PIN, while Pair a Mac is open, and a
    /// PIN pairing in flight.
    let pinBrowser = NativePinBrowser()
    var pinPairing: NativeRunToken?
    var viewerWindow: NativeViewerWindow?
    var listener: NativeTransport?
    var sharingToken: NativeRunToken?
    var hostIdentity: NativeHostIdentity?
    /// Waking this Mac for a viewer left its screen asking for a password, so
    /// automatic sharing waits for an unlock rather than wake it again.
    var needsUnlock = false
    /// A viewer session this Mac's sleep or lock ended: reconnect to it once
    /// this Mac is awake and unlocked again.
    var resumeAfterWake: String?
    var hostChannel: NativeSessionChannel?
    var viewerChannel: NativeSessionChannel?
    var capture: NativeCapture?
    var decoder: NativeVideoDecoder?
    var hostInjector: NativeInputInjector?
    let hostInputGate = NativeHostInputGate()
    let inputEncoder = NativeInputEncoder()
    let hostGeometryLock = NSLock()
    var hostGeometry: NativeDisplayGeometry?
    var viewerInputEnabled = false
    /// At most one connect is in flight: a pairing from the form, or a
    /// connect or reconnect to a saved pairing.
    var connecting: (token: NativeRunToken, peerID: String, pairing: Bool)?
    var statusTimer: Timer?
    var permissionTimer: Timer?
    var observerTokens: [NSObjectProtocol] = []
    var privacyGuard: NativePrivacyGuard?
    var firstFrame = false
    var pingSequence: UInt64 = 0
    var pendingPing: (UInt64, TimeInterval)?
    /// Viewer: the sharing Mac's clock, and screen-change-to-display latency
    /// for the status bar (each second) and the log (every 10 s).
    let clockSync = NativeClockSync()
    var latencySecond = NativeLatencyWindow()
    var latencyReport = NativeLatencyWindow()
    var lastPresented: Double = 0
    var lastStatusTime: TimeInterval = 0
    var lastViewerMeasurements: NativeSessionMeasurements?
    /// Every 10 s the viewer logs where decoded frames went: drawn, waiting
    /// on the GPU, or replaced by newer ones. Local only; never sent.
    var drawReportTicks = 0
    var drawReportDecoded: Double = 0
    var lastHostMeasurements: NativeSessionMeasurements?
    /// Idle display and system sleep would end an active session, so each side
    /// holds a power assertion only while a viewer is connected.
    var hostActivity: NSObjectProtocol?
    var viewerActivity: NSObjectProtocol?
    /// The sharing side's stream settings for this app run; tuning changes them live.
    var hostTuning = NativeTuning.defaults
    var telemetryTimer: Timer?
    var viewerDiagnosticsStream: NativeViewerMeasurementStream?
    var liveLatencies: [(at: TimeInterval, value: (total: Double, toViewer: Double, displayWait: Double))] = []
    /// The running capture's liveness. A restart cancels it first, so callbacks
    /// from the retired capture never reach the session.
    var captureToken: NativeRunToken?
    var captureMaxWidth = 0
    var captureRestartScheduled = false
    var lastCaptureRestart: TimeInterval?
    var retiredEncoderCounters = NativeEncoderCounters()
    /// Host: the bitrate Rust's pacing chose, at most the tuned bitrate, and
    /// how many seconds the connection has been clear.
    var flowKbps: UInt32 = 0
    var flowState = MLFlowState()
    /// A keyframe went out in the last pacing second.
    var keyframeLastSecond = false
    /// The link's rate measured in the last pacing second, kbit/s; 0 if not.
    var lastLinkKbps: UInt32 = 0
    /// Host: the send-buffer limit, read on the capture queue and updated
    /// once a second from the last ten seconds' fastest round trip.
    let flowLimit = NativeFlowLimit()
    /// Why the latest session on this Mac ended, for the log and telemetry.
    var lastEnd: (reason: String, at: TimeInterval)?
    /// Automatic viewer reconnects after an unexpected end; Rust sets the budget.
    var viewerStarted: TimeInterval = 0
    let reconnect: NativeReconnectWorkflow
    var reconnectAttempts: Int { get { reconnect.attempts } set { reconnect.attempts = newValue } }
    var lastViewerEnd = ""
    /// Sends ⌘-Tab and other system shortcuts to the remote Mac while it has focus.
    var systemKeys: NativeSystemKeyCapture?
    /// Found at launch by encoding and decoding one HEVC 4:4:4 frame in hardware.
    var hevc444Available = false
    /// Found at launch by encoding and decoding a tone through Opus.
    var audioAvailable = false
    /// A session announces this Mac's capabilities once, when it starts, so
    /// sharing and connecting wait for the launch self-tests (well under a
    /// second). Without this, a viewer that reconnected the moment this Mac
    /// relaunched after an update got H.264, no sound and no screen matching.
    let capabilityGate = NativeCapabilityGate()
    var capabilitiesReady: Bool { capabilityGate.isReady }
    /// Host: numbers the viewer's sound packets and bounds those waiting.
    var hostAudioGate: NativeAudioSendGate?
    /// Viewer: plays the sharing Mac's sound.
    var audioPlayer: NativeAudioPlayer?
    var audioReported = NativeAudioStats()
    /// Host: follows this Mac's pointer shape for viewers that draw it.
    let cursorWatcher = NativeCursorWatcher()
    /// Host: the display being shared, virtual when a viewer asked for its size.
    let sharedDisplay = NativeSharedDisplay()
    /// Host: keeps part of the menu bar clear beside a viewer's camera housing.
    let menuBarGap = NativeMenuBarGap()
    var pendingDisplayRequest: (width: Int, height: Int, scale: Int)?
    var displayRequestScheduled = false
    var displayRestarts: [TimeInterval] = []
    var displayRestartScheduled = false
    /// Viewer: the last size observed and the last one requested.
    var observedScreenRequest: (width: Int, height: Int, scale: Int)?
    var sentScreenRequest: (width: Int, height: Int, scale: Int)?
    /// Viewer: the camera gap last observed and the last one sent.
    var observedCameraGap: (x: Int, width: Int)?
    var sentCameraGap: (x: Int, width: Int)?
    /// Viewer: the key window also receives pointer moves over the camera
    /// row, so each position is sent once.
    var lastPointerMove: NativeInputEvent?
    /// Exchanges this Mac's clipboard with a connected Mac, polled twice a second.
    let clipboard = NativeClipboardSync()
    var clipboardTimer: Timer?
    /// Stop Sharing holds automatic sharing off until sharing is started again.
    var userStoppedSharing = false
    var nextAutomaticShare: TimeInterval = 0
    var peers: [NativePeer] = [] { didSet { if peers != oldValue { onPeersChange?() } } }
    var onChange: (() -> Void)?
    var onPeersChange: (() -> Void)?
    /// A connection closed during the handshake, which usually means the Macs
    /// run different Mooring versions.
    var onVersionMismatch: (() -> Void)?
    /// Set by the app before launch self-tests finish: this is a release build
    /// that updates itself, so viewers may ask it to.
    var updatesItself = false
    /// Host: a viewer asked this Mac to check for an update now.
    var onUpdateRequest: (() -> Void)?
    /// Viewer: the sharing Mac is newer; check for an update to this Mac.
    var onCheckForUpdates: (() -> Void)?
    /// The other Mac's Mooring version in the current session, if it sent one.
    var viewerPeerVersion: NativeVersion?
    var hostPeerVersion: NativeVersion?
    /// Viewer: the sharing Mac's answer to "Update It".
    var peerUpdate: (state: NativeUpdateState, ready: NativeVersion?, at: TimeInterval)?
    /// Viewer: disconnected so the sharing Mac could install an update, or it
    /// answered but isn't sharing, as when its screen asks for a password;
    /// wait for it to come back on Rust's longer schedule.
    var awaitingPeer: Bool { get { reconnect.awaitingPeer } set { reconnect.awaitingPeer = newValue } }
    /// Viewer: counts Update It requests, so a timeout acts only on its own.
    var updateRequestSerial = 0
    /// Host: a viewer was told its requested update is ready, so it installs
    /// when that session ends even if sharing isn't automatic.
    var viewerAwaitsInstall = false
    /// Relaunching now would interrupt nothing: no session in either role, no
    /// connect or reconnect under way, and any sharing resumes by itself.
    var isIdleForUpdate: Bool {
        !isConnected && hostChannel == nil && connecting == nil && !reconnect.isPending
            && (!isSharing || sharesAutomatically || viewerAwaitsInstall)
    }
    var isSharing: Bool { sharingToken?.isActive == true }
    /// True only after ScreenCaptureKit starts for an authenticated viewer.
    var isSharingScreen = false {
        didSet { if isSharingScreen != oldValue { onChange?() } }
    }
    var isConnected: Bool { viewerChannel?.token.isActive == true }
    /// Start sharing when Mooring opens and resume after sleep, lock or a user switch.
    var sharesAutomatically: Bool {
        get { defaults.bool(forKey: Self.automaticSharingKey) }
        set { defaults.set(newValue, forKey: Self.automaticSharingKey) }
    }
    /// Copy on one Mac, paste on the other, while a session is connected. On by
    /// default; items marked by password managers are never shared.
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
    /// Viewer: full screen on a Mac with a camera housing extends the picture
    /// into the row beside it, where the sharing Mac's menu bar goes, kept
    /// clear of the housing. Needs a matched screen. On by default.
    var extendsBesideCamera: Bool {
        get { defaults.object(forKey: Self.besideCameraKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.besideCameraKey); onChange?() }
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
    /// Presentation preference only; hiding the footer leaves telemetry active.
    var showsDiagnosticBar: Bool {
        get { defaults.object(forKey: Self.diagnosticBarKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.diagnosticBarKey)
            viewerWindow?.setDiagnosticBarVisible(newValue)
            viewerDiagnosticsStream?.signal()
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
    let trust: NativeTrustWorkflow
    let io: NativeSessionIO
    let scheduler: any ConnectionScheduling
    let clock: () -> TimeInterval
    var started = false
    var uptime: TimeInterval { clock() }

    init(dependencies: NativeSessionDependencies = NativeSessionDependencies()) {
        defaults = dependencies.defaults; keychain = dependencies.credentials
        peerStore = dependencies.peers; deviceStore = dependencies.devices
        trust = NativeTrustWorkflow(credentials: dependencies.credentials, peers: dependencies.peers, devices: dependencies.devices)
        reconnect = NativeReconnectWorkflow(scheduler: dependencies.scheduler)
        io = dependencies.io; scheduler = dependencies.scheduler; clock = dependencies.uptime
    }

    /// Wiring a workflow has no platform effects. The app starts it only after
    /// installing observers and update capabilities; tests can exercise use cases
    /// without starting telemetry, media probes or background sharing.
    func start() {
        guard !started, !capabilityGate.isStopped else { return }
        started = true
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
                self.endPINForPrivacy()
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
            self.endPINForPrivacy()
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
        scheduler.after(5) { [weak self] in
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

    func stop() {
        capabilityGate.stop()
        clipboard.stop()
        telemetryTimer?.invalidate(); telemetryTimer = nil
        clipboardTimer?.invalidate(); clipboardTimer = nil
        NativeTelemetryServer.stop()
        stopSharing(); disconnectViewer(reason: "Mooring stopped.", leaving: true)
        systemKeys?.stop(); systemKeys = nil
        privacyGuard?.stop(); privacyGuard = nil
        observerTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observerTokens.removeAll()
    }
}
