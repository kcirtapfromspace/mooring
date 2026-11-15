import AppKit
import IOKit.pwr_mgt
import ApplicationServices
import SystemConfiguration
import CoreVideo
import CryptoKit

// Application workflow implementation. Invariants and wire validation live in Rust.
extension NativeSessionCoordinator {
    func showShare() {
        if shareWindow == nil {
            let controller = NativeShareWindow(); shareWindow = controller
            controller.onToggle = { [weak self] in
                guard let self else { return }
                if self.isSharing { self.stopSharingByUser() } else { self.userStoppedSharing = false; self.startSharing() }
            }
            controller.onCopy = { [weak self] in self?.copyPairingCode() }
            controller.onShowPIN = { [weak self] in self?.showPIN() }
            controller.onReset = { [weak self] in self?.resetPairing() }
            controller.onControlPermission = { [weak self] in self?.allowKeyboardAndMouse() }
            controller.onAutomaticChange = { [weak self] enabled in self?.setSharingAutomatically(enabled) }
            controller.onDiagnostics = { [weak self] in self?.saveDiagnostics(self?.lastHostMeasurements) }
            controller.onClipboardChange = { [weak self] enabled in self?.sharesClipboard = enabled }
        }
        refreshShare()
        refreshPrivacy()
        shareWindow?.showWindow(nil); shareWindow?.window?.center(); NSApp.activate(ignoringOtherApps: true)
    }

    func refreshPrivacy() {
        let local = NativeNetworkInfo.local()
        MooringPrivacy.register(name: NativeDeviceKey.computerName, id: "this-mac", addresses: local.map(\.address))
        for peer in peers { MooringPrivacy.register(name: peer.name, id: peer.id, addresses: peer.addresses) }
        if let devices = approvedDevices()?.devices {
            for device in devices { MooringPrivacy.register(name: device.name, id: device.id) }
        }
        if let window = viewerWindow {
            let name = peers.first { $0.id == window.peerID }?.name ?? "Mac"
            window.window?.title = name + " — Mooring"
        }
        pairWindow?.setPrivacy(MooringPrivacy.isEnabled)
        NotificationCenter.default.post(name: MooringPrivacy.changed, object: nil)
        refreshShare()
    }

    func refreshShare(_ message: String? = nil) {
        shareWindow?.toggle.title = isSharing ? "Stop sharing" : "Start sharing"
        shareWindow?.copy.isEnabled = isSharing
        let idle = sharesAutomatically && !userStoppedSharing ? "Sharing paused · resumes automatically" : "Sharing is off"
        var connected = "Connected · sharing this display"
        if let viewer = hostPeerVersion, viewer != NativeVersion.local { connected += " · the viewer runs \(viewer.name)" }
        var ready = "Ready for your other Mac"
        if !NativePrivacyGuard.mayShareNow() || !NativePrivacyGuard.displayIsAwake {
            ready = "Ready for your other Mac · its connection wakes this display"
        }
        shareWindow?.status.stringValue = isSharing ? (hostChannel == nil ? ready : connected) : idle
        shareWindow?.showControlPermission(NativeInputInjector.isTrusted)
        shareWindow?.automatic.state = sharesAutomatically ? .on : .off
        shareWindow?.clipboard.state = sharesClipboard ? .on : .off
        if let message { shareWindow?.detail.stringValue = message }
        onChange?()
    }

    /// Keyboard and mouse control needs Accessibility on this, the sharing, Mac.
    var keyboardAndMouseAllowed: Bool { NativeInputInjector.isTrusted }
    func allowKeyboardAndMouse() {
        AccessibilityPermission.request()
        shareWindow?.detail.stringValue = "Allow Mooring in Accessibility to control this Mac. Viewing needs no permission."
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
    var listensWhileCovered: Bool { sharesAutomatically && !userStoppedSharing }
    /// Stop reasons say whether sharing comes back by itself.
    func pausedReason(_ reason: String) -> String {
        sharesAutomatically && !userStoppedSharing
            ? reason + " Sharing resumes automatically when this Mac is awake and unlocked."
            : reason + " Start Sharing when ready."
    }

    func capabilitiesAreReady() {
        capabilityGate.complete()
    }
    /// Runs `work` now, or once the launch self-tests finish. At most eight wait.
    func whenCapabilitiesReady(token: NativeRunToken? = nil, _ work: @escaping () -> Void) -> Bool {
        switch capabilityGate.admit(token: token, work) {
        case .ready: return true
        case .waiting: return false
        case .rejected: token?.cancel(); return false
        }
    }

    /// Automatic starts never show a permission prompt; the first manual start asks once.
    func startSharing(automatic: Bool = false) {
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
            refreshShare("Allow Mooring in Screen Recording, then start sharing.")
            return
        }
        do {
            let identity = try preparedHostIdentity()
            let listener = try io.listen(identity, deviceStore)
            let token = NativeRunToken()
            self.listener = listener; sharingToken = token
            NativeLog.session.notice("sharing started \(automatic ? "automatically" : "by the user", privacy: .public)")
            refreshShare("Copy a code to your other Mac. Sharing stays on when this window closes.")
            acceptNext(listener: listener, token: token)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateHostPermission() }
            if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
        } catch { refreshShare(error.localizedDescription) }
    }

    /// This Mac's sharing identity, made on first use, with its list of
    /// approved Macs ready. Sharing and showing a PIN both use it.
    func preparedHostIdentity() throws -> NativeHostIdentity {
        let identity = try trust.prepareHostIdentity()
        hostIdentity = identity
        return identity
    }

    /// Runs at launch and once a second. Retries are spaced five seconds apart.
    /// Automatic sharing listens while the display sleeps or the screen is
    /// covered, as after an update installed then. A timed-out covered session
    /// resumes once it becomes eligible, even if the display is still asleep.
    func resumeSharingIfAutomatic() {
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
    /// Just before an update installs and Mooring relaunches: stop taking
    /// connections, so a viewer waiting for the new version doesn't reach this
    /// one, and remember to share again if sharing was on.
    func prepareForUpdateInstall() {
        guard isSharing else { return }
        if !sharesAutomatically { defaults.set(true, forKey: Self.resumeAfterUpdateKey) }
        stopSharing(reason: "Updating. Sharing resumes when Mooring restarts.")
    }

    func acceptNext(listener: NativeTransport, token: NativeRunToken) {
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

    func beginHost(_ transport: NativeTransport, sharingToken: NativeRunToken) {
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
            scheduler.after(1.5) { [weak self, weak channel] in
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
    func startCapture(for channel: NativeSessionChannel) {
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
            DispatchQueue.main.async { [weak self] in self?.menuBarGap.displayChanged() }
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
            case .success:
                self.isSharingScreen = true
                self.refreshShare(NativeInputInjector.isTrusted ? "Encrypted session · keyboard and mouse enabled." : "Encrypted session · view only. Enable Keyboard & Mouse to allow control.")
            case .failure(let error): channel.fail(error.localizedDescription)
            }
        }
    }

    /// Stops the running capture and keeps its encoder counters.
    func retireCapture() {
        captureToken?.cancel(); captureToken = nil
        isSharingScreen = false
        if let metrics = capture?.encoderMetrics { retiredEncoderCounters.add(metrics) }
        capture?.stop(); capture = nil
    }

    /// Applies a validated tuning update to the sharing side. Bitrate, frame
    /// rate, keyframe interval and in-flight frames change live; a new maximum
    /// width restarts capture at the new size.
    func applyTuning(_ update: NativeTuning) {
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
    func scheduleCaptureRestart() {
        guard !captureRestartScheduled else { return }
        captureRestartScheduled = true
        let wait = lastCaptureRestart.map { max(0, $0 + 1 - uptime) } ?? 0
        scheduler.after(wait) { [weak self] in
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
    func restartCaptureForDisplayChange(_ channel: NativeSessionChannel) {
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
        scheduler.after(0.6) { [weak self, weak channel] in
            guard let self else { return }
            self.displayRestartScheduled = false
            guard let channel, self.hostChannel === channel, channel.token.isActive, self.capture == nil else { return }
            NativeLog.session.notice("display changed; capturing the new main display")
            self.startCapture(for: channel)
        }
    }

    /// Retires capture and holds input until the viewer has the new geometry.
    /// Whoever paused resumes capture; if nothing has after 5 s, this does.
    func pauseCaptureForDisplayChange() {
        retireCapture()
        hostGeometryLock.lock(); hostGeometry = nil; hostGeometryLock.unlock()
        hostInjector?.releaseAll()
        guard let channel = hostChannel else { return }
        scheduler.after(5) { [weak self, weak channel] in
            guard let self, let channel, self.hostChannel === channel, channel.token.isActive, self.capture == nil else { return }
            NativeLog.session.notice("display change did not finish; capturing the current main display")
            self.startCapture(for: channel)
        }
    }

    /// The viewer's latest request wins; it applies after half a second of quiet.
    func requestDisplay(width: Int, height: Int, scale: Int, channel: NativeSessionChannel) {
        pendingDisplayRequest = (width, height, scale)
        guard !displayRequestScheduled else { return }
        displayRequestScheduled = true
        scheduler.after(0.5) { [weak self, weak channel] in
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

    func updateHostPermission() {
        guard NativePrivacyGuard.mayShareNow() else {
            // While covered, an approved Mac's connection is waking it, or nothing is connected.
            if hostChannel != nil || !listensWhileCovered || !NativePrivacyGuard.mayListenNow() {
                pauseSharing("This Mac is no longer active.")
            }
            return
        }
        hostInputGate.invalidate()
        let trusted = NativeInputInjector.isTrusted
        shareWindow?.showControlPermission(trusted)
        guard let channel = hostChannel, channel.token.isActive else { return }
        if !trusted { hostInjector?.releaseAll() }
        capture?.setShowsCursor(!trusted)
        channel.control(.inputState(enabled: trusted))
    }

    /// Rust admits only input, ping and keyframe requests here, enforces rate
    /// and spacing limits, and ends the session when the viewer goes idle.
    func readHost(_ channel: NativeSessionChannel, injector: NativeInputInjector) {
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
                    case .control(.menuBarGap(let x, let width)):
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel else { return }
                            self.menuBarGap.request(x: x, width: width)
                        }
                    case .control(.hello(let capabilities)):
                        // Rust has recorded the viewer's capabilities; start with the best shared codec.
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel else { return }
                            if capabilities & UInt64(ML_CAPABILITY_CURSOR) != 0 { self.cursorWatcher.start(); self.cursorWatcher.resend() }
                            if capabilities & UInt64(ML_CAPABILITY_MENU_BAR_GAP) != 0 {
                                self.menuBarGap.onHeight = { [weak self, weak channel] height in
                                    guard let self, let channel, self.hostChannel === channel, channel.token.isActive else { return }
                                    channel.control(.menuBar(height: height))
                                }
                                self.menuBarGap.start()
                            }
                            if capabilities & UInt64(ML_CAPABILITY_VERSION) != 0 { channel.control(.version(.local)) }
                            if self.capture == nil { self.startCapture(for: channel) }
                        }
                    case .control(.version(let version)):
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel else { return }
                            self.hostPeerVersion = version
                            NativeLog.session.notice("viewer runs Mooring \(version.name, privacy: .public) (build \(version.build))")
                            self.refreshShare()
                        }
                    case .control(.revokePairing):
                        // Rust has already persisted removal of the key this
                        // session authenticated, before delivering the notice.
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.hostChannel === channel else { return }
                            self.endHost(reason: "The viewing Mac removed this pairing. A new code is required.")
                        }
                        // This is terminal. Reading the sender's immediate EOF
                        // would cancel the channel before its queued notice runs.
                        return
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

    func endHost(reason: String, revoking: Bool = false) {
        recordEnd("host", reason)
        if revoking, let channel = hostChannel, channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_PAIRING_REVOCATION) != 0 {
            channel.close(after: .control(.revokePairing))
        } else { hostChannel?.close() }
        hostChannel = nil; hostAudioGate = nil; hostPeerVersion = nil
        refreshClipboardScope(includeCurrent: false)
        cursorWatcher.stop()
        sharedDisplay.release(); pendingDisplayRequest = nil; displayRestarts = []; menuBarGap.stop()
        endHostActivity()
        retireCapture(); hostInjector?.stop(); hostInjector = nil
        hostGeometryLock.lock(); hostGeometry = nil; hostGeometryLock.unlock()
        refreshShare(reason + " Waiting for a new connection.")
        if let listener, let token = sharingToken, token.isActive { acceptNext(listener: listener, token: token) }
    }
    /// This Mac's display slept, or its screen was covered or locked. A session
    /// ends at once: a covered screen is never shared. With automatic sharing
    /// this Mac keeps listening; otherwise sharing stops.
    func pauseSharing(_ reason: String) {
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
    func wakeForViewer(_ transport: NativeTransport, sharingToken: NativeRunToken) {
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
    func checkWake(_ transport: NativeTransport, sharingToken: NativeRunToken, started: TimeInterval,
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
        scheduler.after(0.1) { [weak self] in
            guard let self else { transport.close(); activity.stop(); return }
            self.checkWake(transport, sharingToken: sharingToken, started: started, activity: activity, state: pendingState)
        }
    }

    /// Stop Sharing in the window or menu. Automatic sharing stays off until
    /// the user starts sharing again or Mooring next opens.
    func stopSharingByUser() {
        userStoppedSharing = true
        stopSharing(reason: sharesAutomatically
            ? "Sharing stopped. It starts automatically again the next time Mooring opens, or click Start Sharing."
            : "Sharing stopped. Your paired Macs can reconnect the next time you start sharing.")
    }

    func stopSharing(reason: String = "Sharing stopped. Your paired Macs can reconnect the next time you start sharing.") {
        if hostChannel != nil { recordEnd("host", reason) }
        if sharingToken != nil { NativeLog.session.notice("sharing stopped: \(reason, privacy: .public)") }
        sharingToken?.cancel(); sharingToken = nil
        listener?.close(); listener = nil
        hostChannel?.close(); hostChannel = nil; hostAudioGate = nil; hostPeerVersion = nil
        refreshClipboardScope(includeCurrent: false)
        cursorWatcher.stop()
        sharedDisplay.release(); pendingDisplayRequest = nil; displayRestarts = []; menuBarGap.stop()
        endHostActivity()
        retireCapture(); hostInjector?.stop(); hostInjector = nil
        permissionTimer?.invalidate(); permissionTimer = nil
        hostGeometryLock.lock(); hostGeometry = nil; hostGeometryLock.unlock()
        refreshShare(reason)
    }

    func endHostActivity() {
        if let hostActivity { ProcessInfo.processInfo.endActivity(hostActivity) }
        hostActivity = nil
    }

    /// Reasons are Mooring's own text or fixed Rust and Apple error text: never
    /// addresses, names or pairing material, so they are logged as public.
    func recordEnd(_ role: String, _ reason: String) {
        lastEnd = (reason, uptime)
        NativeLog.session.notice("\(role, privacy: .public) session ended: \(reason, privacy: .public)")
    }

    /// A one-time code: it approves one Mac within ten minutes while this
    /// listener runs, and a newer code replaces it.
}
