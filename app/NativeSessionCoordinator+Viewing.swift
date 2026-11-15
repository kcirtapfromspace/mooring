import AppKit
import IOKit.pwr_mgt
import ApplicationServices
import SystemConfiguration
import CoreVideo
import CryptoKit

// Application workflow implementation. Invariants and wire validation live in Rust.
extension NativeSessionCoordinator {
    func returnToViewer(_ peerID: String) -> Bool {
        guard isConnected, let viewerWindow, viewerWindow.peerID == peerID else { return false }
        viewerWindow.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        return true
    }
    /// Remove a pairing from this Mac: its saved metadata and its Keychain secret.
    func forget(peerID: String) throws {
        // Erase the credential/key before removing the row. If Keychain refuses
        // both deletion and erasure, keep the row and session intact for retry.
        try trust.forget(peerID: peerID)
        NativeInternetLinks.shared.removeRoute(for: peerID)
        if resumeAfterWake == peerID { resumeAfterWake = nil }
        if connecting?.peerID == peerID { cancelConnect() }
        if viewerWindow?.peerID == peerID {
            disconnectViewer(reason: "This pairing was removed. Pair again with a new code.", revoking: true)
            stopReconnecting()
            viewerWindow?.showEnded(reason: "This pairing was removed. Pair again with a new code.")
        }
        peers = (try? peerStore.load()) ?? peers.filter { $0.id != peerID }
    }
    /// A user's connect or Reconnect click; it starts a fresh reconnect budget.
    /// Another Mac on screen stays connected until this one connects.
    func connect(peerID: String) {
        resumeAfterWake = nil
        if returnToViewer(peerID) { return }
        stopReconnecting()
        startConnect(peerID: peerID)
    }
    func startConnect(peerID: String, automatic: Bool = false) {
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
    /// Mooring forward or take keyboard focus from another app.
    /// `addresses` are tried together, the first preferred.
    func connect(code: NativePairingCode, addresses: [String], pairing: Bool = false, automatic: Bool = false) {
        guard !(automatic && isConnected), !capabilityGate.isStopped else { return }
        // Its code while it's on screen: that Mac is busy showing this one, so
        // pairing again can't reach it. Bring its session forward instead.
        if returnToViewer(code.peerID) {
            if pairing { pairWindow?.code.stringValue = ""; pairWindow?.close() }
            return
        }
        if let current = connecting {
            // A new pairing, or a user's connect to another Mac, takes over
            // from reconnecting; anything else waits.
            guard !current.pairing, pairing || (!automatic && current.peerID != code.peerID) else { return }
            endReconnecting(reason: lastViewerEnd.isEmpty
                            ? (pairing ? "Reconnecting stopped for a new pairing." : "Reconnecting stopped for another Mac.") : lastViewerEnd)
        }
        var candidates: [String] = []
        for entry in addresses {
            guard let address = NativePairingCode.normalizedAddress(entry) else {
                pairWindow?.showError("Enter a hostname or IP address without a port."); return
            }
            if !candidates.contains(address) { candidates.append(address) }
        }
        let addresses = Array(candidates.prefix(Int(ML_ADDRESSES_MAX)))
        let attempt = NativeRunToken(), peerID = code.peerID
        connecting = (attempt, peerID, pairing)
        if pairing { pairWindow?.setBusy(true); pairWindow?.showError("") }
        guard whenCapabilitiesReady(token: attempt, { [weak self] in
            self?.beginConnect(code: code, addresses: addresses, pairing: pairing, automatic: automatic, attempt: attempt)
        }) else {
            if !attempt.isActive, connecting?.token === attempt { cancelConnect() }
            return
        }
        beginConnect(code: code, addresses: addresses, pairing: pairing, automatic: automatic, attempt: attempt)
    }

    func beginConnect(code: NativePairingCode, addresses: [String], pairing: Bool, automatic: Bool, attempt: NativeRunToken) {
        guard attempt.isActive, connecting?.token === attempt, !capabilityGate.isStopped else { return }
        let peerID = code.peerID
        let deviceKey: NativeDeviceKey
        do { deviceKey = try pairing ? NativeDeviceKey.create() : keychain.peerDeviceKey(peerID) } catch {
            connecting = nil
            if pairing { pairWindow?.setBusy(false) }
            connectFailed(error, peerID: peerID, pairing: pairing); return
        }
        if let window = openViewerWindow(for: peerID) {
            window.status.stringValue = "Connecting…"
            if !window.isReconnecting { window.showConnecting() }
        }
        let connectIO = io.connect
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard attempt.isActive else { return }
            do {
                let (transport, mode, used) = try connectIO(addresses, code, deviceKey)
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
                                try self.keychain.savePeerCode(saved, deviceKey: deviceKey)
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
                        try self.keychain.savePeerCode(saved, deviceKey: deviceKey)
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
    func connectFailed(_ error: Error, peerID: String, pairing: Bool = false, kind: NativePairingCode.Kind? = nil) {
        var message = error.localizedDescription
        let refused = (error as? NativeSessionError)?.isAuthenticationFailure == true
        let notSharing = (error as? NativeSessionError)?.isNotSharing == true
        if notSharing {
            message = "The sharing Mac answered, but Mooring isn't sharing there right now. Its screen may be locked with a password: "
                + "unlock it, for example with Screen Sharing, and Mooring reconnects within seconds."
        }
        if refused && pairing {
            message = kind == .oneTime
                ? "The sharing Mac didn't accept this code. A code works once, on one Mac, within 10 minutes, and a newer code "
                    + "replaces it. Copy a new code on that Mac and try again."
                : "The sharing Mac no longer accepts this older code. Copy a new code on that Mac and try again."
        }
        // Different versions end the handshake without a reason on the other side.
        if [Int32(ML_SESSION_CLOSED), Int32(ML_SESSION_PROTOCOL)].contains((error as? NativeSessionError)?.status ?? 0) {
            message += " If the other Mac runs a different Mooring version, update both Macs."
            onVersionMismatch?()
        }
        if pairing {
            if pairWindow?.window?.isVisible == true { pairWindow?.showError(message) } else { showError(message) }
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
    func cancelConnect() {
        if connecting?.pairing == true { pairWindow?.setBusy(false) }
        connecting?.token.cancel(); connecting = nil
    }

    /// The open window already showing this paired Mac, if any.
    func openViewerWindow(for peerID: String) -> NativeViewerWindow? {
        guard let window = viewerWindow, window.peerID == peerID, !window.isClosed else { return nil }
        return window
    }
    /// Schedules the next automatic attempt; false once Rust's budget is spent.
    func scheduleReconnect(_ window: NativeViewerWindow, reason: String) -> Bool {
        let peerID = window.peerID
        guard let attempt = reconnect.schedule({ [weak self] in
            guard let self else { return }
            guard !self.isConnected, let window = self.openViewerWindow(for: peerID) else { return }
            // A pairing in flight holds the only connect slot; count this attempt and wait.
            guard self.connecting == nil else {
                if !self.scheduleReconnect(window, reason: reason) { window.showEnded(reason: reason) }
                return
            }
            self.startConnect(peerID: peerID, automatic: true)
        }) else { return false }
        window.showReconnecting(reason: reason, attempt: attempt.number, of: attempt.limit)
        NativeLog.session.notice("viewer reconnect \(attempt.number) of \(attempt.limit) in \(attempt.milliseconds) ms")
        return true
    }
    func stopReconnecting() {
        reconnect.reset()
    }
    /// Stops reconnecting and any connect in flight; a window still saying
    /// "Reconnecting…" shows `reason` instead.
    func endReconnecting(reason: String) {
        stopReconnecting(); cancelConnect()
        if viewerChannel == nil, let window = viewerWindow, !window.isClosed, window.isReconnecting { window.showEnded(reason: reason) }
    }

    /// `pairing`: the clipboard may still hold the code just pasted, so what is
    /// already copied is not shared for this first session.
    func beginViewer(_ transport: NativeTransport, peer: NativePeer, activate: Bool, pairing: Bool = false) {
        // One Mac on screen at a time: the one showing leaves now that this one connected.
        if viewerChannel != nil { disconnectViewer(reason: "Switched to another Mac.", leaving: true) }
        MooringPrivacy.register(name: peer.name, id: peer.id, addresses: peer.addresses)
        let channel = NativeSessionChannel(transport), decoder = NativeVideoDecoder()
        viewerChannel = channel; self.decoder = decoder; lastViewerMeasurements = channel.measurements
        firstFrame = false; viewerInputEnabled = false; pendingPing = nil; lastPresented = 0; lastStatusTime = uptime
        clockSync.reset(); latencySecond = NativeLatencyWindow(); latencyReport = NativeLatencyWindow()
        liveLatencies = []
        drawReportTicks = 0; drawReportDecoded = 0
        observedScreenRequest = nil; sentScreenRequest = nil
        observedCameraGap = nil; sentCameraGap = nil; lastPointerMove = nil
        viewerStarted = uptime; reconnect.cancelPending()
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
            viewerWindow?.video.onInput = nil; viewerWindow?.video.onReleaseInput = nil; viewerWindow?.cameraRowVideo.onInput = nil
            viewerWindow?.close()
            window = NativeViewerWindow(name: peer.name, peerID: peer.id, showsDiagnosticBar: showsDiagnosticBar); viewerWindow = window
        }
        window.onDiagnosticBarChange = { [weak self] visible in self?.showsDiagnosticBar = visible }
        window.updateDiagnostics(NativeViewerDiagnostics())
        viewerDiagnosticsStream?.stop()
        let diagnosticsStream = NativeViewerMeasurementStream(measurements: channel.measurements) { [weak self, weak channel] interval in
            guard let self, let channel, self.viewerChannel === channel, channel.token.isActive else { return }
            self.updateViewerDiagnostics(channel, interval: interval)
        }
        viewerDiagnosticsStream = diagnosticsStream
        channel.measurements.observeChanges { [weak diagnosticsStream] in diagnosticsStream?.signal() }
        window.onViewportChange = { [weak diagnosticsStream] in diagnosticsStream?.signal() }
        diagnosticsStream.signal()
        viewerActivity = viewerActivity ?? ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
            reason: "Showing a paired Mac")
        window.onReconnect = { [weak self] in self?.connect(peerID: peer.id) }
        window.onCancelReconnect = { [weak self, weak window] in
            guard let self, let window, self.viewerWindow === window else { return }
            self.endReconnecting(reason: self.lastViewerEnd.isEmpty ? "Reconnecting was cancelled." : self.lastViewerEnd)
        }
        window.onAllowSystemKeys = {
            AccessibilityPermission.request()
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
        window.cameraRowVideo.onInput = { [weak self, weak channel, weak row = window.cameraRowVideo] event in
            guard let self, let channel, self.viewerChannel === channel else { return }
            self.sendInput(event, from: row)
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
        let capturing = keys.start()
        window.setSystemKeysAllowed(capturing)
        NativeLog.session.notice("\(capturing ? "⌘-Tab and other system shortcuts go to the sharing Mac" : "⌘-Tab and other system shortcuts stay on this Mac until Mooring is allowed in Accessibility", privacy: .public)")
        let firstPresentationPending = NativeRunToken()
        window.video.onFrameTiming = { [weak self, weak channel] timing in
            guard let self, let channel, self.viewerChannel === channel, let latency = self.clockSync.latency(timing) else { return }
            self.latencySecond.add(latency); self.latencyReport.add(latency)
            self.liveLatencies.append((self.uptime, latency))
            if self.liveLatencies.count > 120 { self.liveLatencies.removeFirst(self.liveLatencies.count - 120) }
            self.viewerDiagnosticsStream?.signal()
        }
        window.video.onPresented = { [weak self, weak channel] in
            guard let channel, channel.token.isActive else { return }
            channel.measurements.add("presented_frames")
            if firstPresentationPending.cancel() {
                channel.measurements.set("first_presented_frame_ms", channel.measurements.snapshot()["session_seconds", default: 0] * 1000)
                DispatchQueue.main.async {
                    guard let self, self.viewerChannel === channel, channel.token.isActive, let viewer = self.viewerWindow else { return }
                    self.firstFrame = true
                    self.viewerDiagnosticsStream?.signal()
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
    func readViewer(_ channel: NativeSessionChannel, decoder: NativeVideoDecoder) {
        let player = audioPlayer
        let diagnosticsStream = viewerDiagnosticsStream
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak channel] in
            guard let self, let channel else { return }
            while channel.token.isActive {
                do {
                    guard let message = try channel.transport.receive() else { continue }
                    switch message {
                    case .video(let packet):
                        channel.measurements.add("received_video_frames"); channel.measurements.add("received_video_bytes", Double(packet.wireSize))
                        channel.measurements.set("video_codec", Double(packet.codec.raw))
                        _ = decoder.decode(packet)
                        channel.measurements.set("decoder_overflows", Double(decoder.overflows))
                    case .control(.revokePairing):
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.viewerChannel === channel else { return }
                            self.apply(.revokePairing, channel: channel)
                        }
                        return
                    case .control(let control):
                        channel.deliverControl { [weak self, weak channel] in
                            guard let self, let channel, self.viewerChannel === channel, channel.token.isActive else { return }
                            self.apply(control, channel: channel)
                            diagnosticsStream?.signal()
                        }
                    case .telemetry(.stats(let stats)):
                        channel.storePeerStats(stats)
                        diagnosticsStream?.signal()
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
                        diagnosticsStream?.signal()
                    case .input, .telemetry(.tuning):
                        throw NativeSessionError(message: "The sharing Mac sent an unexpected message.")
                    }
                } catch { if channel.token.isActive { channel.fail(error.localizedDescription) }; return }
            }
        }
    }
    func apply(_ control: NativeControlMessage, channel: NativeSessionChannel) {
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
            NativeLog.session.notice("sharing Mac runs Mooring \(version.name, privacy: .public) (build \(version.build))")
            refreshVersionNotice()
        case .updateStatus(let state, let ready):
            peerUpdate = (state, ready, uptime)
            NativeLog.updates.notice("sharing Mac update check: \(String(describing: state), privacy: .public)")
            refreshVersionNotice()
        case .revokePairing:
            let peerID = viewerWindow?.peerID
            disconnectViewer(reason: "The sharing Mac removed this pairing. Pair again with a new code.")
            if let peerID {
                // A failed Keychain cleanup must never restart a revoked session.
                try? keychain.deletePeerCode(peerID)
            }
        case .menuBar(let height):
            if viewerWindow?.remoteMenuBarHeight != height {
                NativeLog.session.notice("the sharing Mac's menu bar is \(height) points tall")
            }
            viewerWindow?.setRemoteMenuBar(height: height)
        case .ping, .keyframe, .displayRequest, .updateRequest, .leaving, .menuBarGap:
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
    func refreshVersionNotice() {
        guard let window = viewerWindow else { return }
        guard let peer = viewerPeerVersion, let channel = viewerChannel, channel.token.isActive else {
            window.setVersionNotice(nil); return
        }
        let local = NativeVersion.local
        window.status.toolTip = "The sharing Mac runs Mooring \(peer.name); this Mac runs \(local.name)."
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
                    scheduler.after(wait) { [weak self] in self?.refreshVersionNotice() }
                }
            }
        case .orderedAscending:
            window.setVersionNotice("This Mac runs \(local.name), the sharing Mac \(peer.name) · Check for Updates", enabled: true)
        case .orderedSame, nil:
            window.setVersionNotice(nil)
        }
    }
    func versionNoticeClicked() {
        guard let peer = viewerPeerVersion, let channel = viewerChannel, channel.token.isActive else { return }
        switch NativeVersion.local.compared(to: peer) {
        case .orderedAscending:
            onCheckForUpdates?()
        case .orderedDescending:
            if case .some((.ready, let ready, _)) = peerUpdate {
                awaitingPeer = true; reconnectAttempts = 0
                NativeLog.updates.notice("disconnecting so the sharing Mac can install \(ready?.name ?? "its update", privacy: .public)")
                disconnectViewer(reason: "The sharing Mac is installing \(ready?.name ?? "an update") and will restart. Mooring reconnects when it's back.",
                                 reconnect: true)
            } else {
                peerUpdate = (.checking, nil, uptime)
                updateRequestSerial += 1
                let serial = updateRequestSerial
                channel.control(.updateRequest)
                refreshVersionNotice()
                // A check that never answers, as when the sharing Mac shows an
                // update window, may be asked again after 90 s.
                scheduler.after(90) { [weak self] in
                    guard let self, self.updateRequestSerial == serial, self.peerUpdate?.state == .checking else { return }
                    self.peerUpdate = (.failed, nil, self.uptime - 61)
                    self.refreshVersionNotice()
                }
            }
        default:
            break
        }
    }
    func setViewerInput(_ enabled: Bool) {
        if !enabled { releaseViewerInput() }
        viewerInputEnabled = enabled
        viewerWindow?.video.forwardsCommandKeys = enabled
        if enabled, systemKeys?.isRunning != true { viewerWindow?.noteSystemKeysStayLocal() }
        // View only: the sharing Mac draws its own pointer into the video, so
        // hide this Mac's pointer over it. With control, the reverse applies.
        viewerWindow?.video.hidesLocalCursor = !enabled
    }

    /// True while a connected, controlling session's video has keyboard focus.
    var viewerHasKeyboardFocus: Bool {
        guard let channel = viewerChannel, channel.token.isActive, viewerInputEnabled, firstFrame, NSApp.isActive,
              let window = viewerWindow?.window, window.isKeyWindow,
              let view = viewerWindow?.video, window.firstResponder === view else { return false }
        return true
    }
    /// `source`: the view the event arrived in; the main video by default.
    func sendInput(_ event: NSEvent, from source: NativeRemoteView? = nil) {
        guard viewerHasKeyboardFocus, let channel = viewerChannel, let window = viewerWindow else { return }
        let view = source ?? window.video
        inputEncoder.holdsPointerAtEdges = window.window?.styleMask.contains(.fullScreen) == true
        guard view.geometry != nil, view.displayedVideoRect.width > 0, view.displayedVideoRect.height > 0,
              let input = inputEncoder.encode(event, in: view, contentRect: view.displayedVideoRect) else { return }
        // Rust refuses gestures to a host that did not announce it injects them.
        if input.kind.isGesture, channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_GESTURES) == 0 { return }
        if input.kind == .pointerMove && input == lastPointerMove { return }
        lastPointerMove = input.kind == .pointerMove ? input : nil
        channel.send(.input(input))
    }
    func releaseViewerInput() {
        let event = inputEncoder.releaseAll()
        guard let channel = viewerChannel, channel.token.isActive else { return }
        channel.send(.input(event))
    }
    func updateViewerStatus() {
        guard let channel = viewerChannel, channel.token.isActive else { return }
        // Accessibility can be granted mid-session; start capturing ⌘-Tab then.
        if let keys = systemKeys, !keys.isRunning {
            let started = keys.start()
            viewerWindow?.setSystemKeysAllowed(started)
            if started { NativeLog.session.notice("Accessibility allowed: ⌘-Tab and other system shortcuts now go to the sharing Mac") }
        }
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
        requestMatchingScreen(channel)
        requestCameraGap(channel)
        if let pendingPing, now - pendingPing.1 > 8 { channel.fail("The sharing Mac stopped answering connection checks."); return }
        if pendingPing == nil {
            pingSequence &+= 1; pendingPing = (pingSequence, now)
            channel.control(.ping(pingSequence))
        }
    }
    /// Once a second: when the video area has kept the same size for a tick,
    /// ask a capable sharing Mac for a display exactly that size at this Mac's
    /// Retina scale, so the picture fills the window pixel for pixel.
    func requestMatchingScreen(_ channel: NativeSessionChannel) {
        guard firstFrame, channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_VIRTUAL_DISPLAY) != 0,
              let viewer = viewerWindow, let window = viewer.window else { return }
        viewer.extendsBesideCamera = matchesScreen && extendsBesideCamera
            && channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_MENU_BAR_GAP) != 0
        var desired: (width: Int, height: Int, scale: Int) = (0, 0, 0)
        if matchesScreen {
            let scale = window.backingScaleFactor >= 2 ? 2 : 1
            var width = Double(viewer.pictureSize.width), height = Double(viewer.pictureSize.height)
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
    /// Once a second, beside requestMatchingScreen: while the picture extends
    /// beside this Mac's camera housing, ask the sharing Mac to keep that part
    /// of its menu bar clear, and to stop when it no longer does. A gap is sent
    /// once it has held for a tick, so a display change in progress isn't.
    func requestCameraGap(_ channel: NativeSessionChannel) {
        guard firstFrame, channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_MENU_BAR_GAP) != 0,
              let viewer = viewerWindow else { return }
        let gap = viewer.video.geometry.flatMap { viewer.cameraGap(remoteWidth: $0.width) } ?? (x: 0, width: 0)
        defer { observedCameraGap = gap }
        guard let observed = observedCameraGap, observed == gap else { return }
        if let sent = sentCameraGap, sent == gap { return }
        if sentCameraGap == nil && gap.width == 0 { return }
        sentCameraGap = gap
        channel.control(.menuBarGap(x: gap.x, width: gap.width))
        NativeLog.session.notice("\(gap.width > 0 ? "asked the sharing Mac to keep \(gap.width) points of its menu bar clear for this Mac's camera" : "the sharing Mac's menu bar no longer needs a gap", privacy: .public)")
    }
    /// This Mac is going to sleep or locked. A session, or reconnecting, ends
    /// now, without telling the sharing Mac it's leaving, so it waits; this
    /// Mac reconnects once it's awake and unlocked.
    func pauseViewer(reason: String) {
        let peerID = viewerWindow.flatMap { window in
            !window.isClosed && (viewerChannel != nil || connecting != nil || window.isReconnecting) ? window.peerID : nil
        }
        disconnectViewer(reason: peerID == nil ? reason + " Reconnect when ready." : reason + " Mooring reconnects when this Mac is awake and unlocked.")
        if let peerID { resumeAfterWake = peerID; NativeLog.session.notice("viewer paused; it reconnects after this Mac wakes") }
    }
    /// Runs once a second: reconnects a session this Mac's sleep or lock
    /// ended, once it's awake and unlocked, with a fresh reconnect budget.
    func resumeViewerAfterWake() {
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
    func disconnectViewer(reason: String, reconnect: Bool = false, leaving: Bool = false, revoking: Bool = false) {
        if !reconnect { endReconnecting(reason: reason) }
        if leaving { resumeAfterWake = nil }
        // Privacy and sleep events call this with no session; leave any window
        // from an earlier session showing its own reason.
        guard let channel = viewerChannel else { return }
        channel.measurements.observeChanges(nil)
        viewerDiagnosticsStream?.stop(); viewerDiagnosticsStream = nil; liveLatencies = []
        let lasted = uptime - viewerStarted
        recordEnd("viewer", reason); lastViewerEnd = reason
        releaseViewerInput()
        if revoking && channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_PAIRING_REVOCATION) != 0 {
            channel.close(after: .control(.revokePairing))
        } else if leaving && channel.transport.peerCapabilities & UInt64(ML_CAPABILITY_WAITS) != 0 {
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
        viewerWindow?.updateDiagnostics(NativeViewerDiagnostics(state: reason))
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

}
