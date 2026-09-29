import AppKit
import Network
import ServiceManagement

private final class AutomationIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    func cancel() { lock.lock(); active = false; lock.unlock() }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
}

/// Main-thread coordinator; all Accessibility work is isolated on its serial queue.
/// Rust evaluates measured target reachability. Apple still owns the video stream.
final class AutomationCoordinator: MacLinkAutomationService {
    private let cli: CLIClient
    private var settings: AutomationSettings
    private var connections: [SavedMac] = []
    private var settingsWindow: AutomationSettingsController?
    private let session = AppleSession()
    private let sessionQueue = DispatchQueue(label: "dev.maclink.session")
    private let monitor = NWPathMonitor()
    private var path: NWPath?
    private var timer: Timer?
    private var generation = 0
    private var networkGeneration = 0
    private var intent = AutomationIntent()
    private var probeBusy = false
    private var observationBusy = false
    private var launchBusy = false
    private var sessionRequested = false
    private var sessionConnected = false
    private var requestedMode: String?
    private var sessionIssue: String?
    private var policyState: [String: Any]?
    private var latestProbe: [String: Any]?
    private var routeFingerprint: String?
    private var localNetworkFingerprint: String?
    private var routeDescription = "Check the saved Mac to identify its current path."
    private var recommendation = "standard"
    private var reachable = false
    private var firstProbeAt: TimeInterval?
    private var nextProbeAt: TimeInterval = 0
    private var offlineCooling = false
    private var lastLaunchAt: TimeInterval = -.infinity
    private var launches = 0
    private var crashFallback = false
    private var stopped = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private(set) var state = AutomationMenuState()
    var onStateChange: ((AutomationMenuState) -> Void)?

    init(cli: CLIClient) {
        self.cli = cli
        // Isolated QA never reads or changes the installed app's settings.
        if let suite = ProcessInfo.processInfo.environment["MACLINK_DEFAULTS_SUITE"] {
            defaults = UserDefaults(suiteName: suite) ?? .standard
        } else { defaults = .standard }
        if let data = defaults.data(forKey: "automation.v1"),
           let saved = try? JSONDecoder().decode(AutomationSettings.self, from: data) { settings = saved }
        else { settings = AutomationSettings() }
    }
    private var target: SavedMac? { connections.first { $0.id == settings.targetID } }
    var selectedPreference: String { settings.preference }
    func setPreference(_ preference: String) {
        guard ["auto", "standard", "high_performance"].contains(preference), !launchBusy else { return }
        if preference == "high_performance" && !settings.highPerformanceConfirmed {
            showSettings(connections: connections, parentWindow: nil); return
        }
        settings.preference = preference; save(); invalidateEvidence()
        if preference == "standard", requestedMode != "standard", sessionConnected, !settings.paused, let mac = target, AppleSession.isTrusted {
            reconnect(mac, mode: "standard")
        } else { refreshIdleState(); tick() }
    }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func publish(_ title: String, _ detail: String) {
        state = AutomationMenuState(title: title, detail: detail, isConfigured: settings.enabled && target != nil,
                                    isPaused: settings.paused, isBusy: launchBusy)
        onStateChange?(state)
    }
    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "automation.v1") }
    }
    func start(connections: [SavedMac]) {
        self.connections = connections
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                let changed = self.path != nil
                self.path = path
                if changed || path.status != .satisfied {
                    self.invalidateNetwork("The network changed. Detect it again before marking it as home.")
                }
                if path.status != .satisfied {
                    if self.settings.enabled && !self.settings.paused { self.publish("Waiting for network", "The saved Mac will be checked when connectivity returns.") }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.maclink.network-path"))
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.invalidateNetwork("The Mac is going to sleep. Detect the network again after waking.")
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.invalidateNetwork("The Mac woke up. Detect the current network again."); self?.tick()
        })
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        refreshIdleState(); tick()
    }
    func updateConnections(_ connections: [SavedMac]) {
        self.connections = connections
        settingsWindow?.updateConnections(connections)
        if target == nil { invalidateEvidence(); sessionRequested = false; sessionConnected = false }
        refreshIdleState()
    }
    private func invalidateEvidence() {
        intent.cancel(); intent = AutomationIntent()
        generation += 1; policyState = nil; latestProbe = nil; firstProbeAt = nil
        routeFingerprint = nil; reachable = false; recommendation = "standard"
        localNetworkFingerprint = nil
        nextProbeAt = 0; offlineCooling = false
    }
    private func invalidateNetwork(_ reason: String) {
        networkGeneration += 1
        invalidateEvidence()
        settingsWindow?.invalidateHomeCheck(reason: reason)
    }
    private func refreshIdleState() {
        if !settings.enabled { publish("Automation is off", "Choose a Mac and enable automation in Settings.") }
        else if target == nil { publish("Choose a Mac", "The saved automation target is missing. Open Settings.") }
        else if settings.paused { publish("Automation paused", "Resume from this menu when you want automatic connections again.") }
        else if !AppleSession.isTrusted { publish("Accessibility setup needed", "Open Settings to enable session tracking, full screen and reconnects.") }
        else { publish("Evaluating connection…", "Checking the path to your saved Mac.") }
    }
    func togglePause() {
        settings.paused.toggle(); save(); invalidateEvidence()
        if !settings.paused {
            launches = 0
            if !sessionConnected { sessionRequested = false; sessionQueue.async { self.session.reset() } }
        }
        refreshIdleState(); tick()
    }
    func stop() {
        intent.cancel()
        stopped = true; generation += 1; timer?.invalidate(); monitor.cancel()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }
    private func tick() {
        guard !stopped, settings.enabled, !settings.paused, let mac = target else { return }
        if sessionRequested && !launchBusy { observeSession() }
        guard !probeBusy, !launchBusy, now >= nextProbeAt else { return }
        probe(mac)
    }
    private func probe(_ mac: SavedMac) {
        guard !probeBusy else { return }
        probeBusy = true
        let epoch = generation
        cli.run(["network-probe", mac.id], timeout: 6) { [weak self] result in
            guard let self else { return }
            self.probeBusy = false
            guard !self.stopped, epoch == self.generation else { return }
            let response: [String: Any]
            switch result {
            case .success(let data): response = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            case .failure(let error): response = ["status": "connect_failed", "error": error.message]
            }
            self.receiveProbe(response, mac: mac)
        }
    }
    private func receiveProbe(_ response: [String: Any], mac: SavedMac) {
        let inspection = response["inspection"] as? [String: Any] ?? [:]
        let route = response["route"] as? [String: Any] ?? [:]
        let success = response["status"] as? String == "rfb_ready"
        var measuredFingerprint: String?
        let measuredDescription: String
        if success, let address = inspection["resolved_address"] as? String, let interface = route["interface"] as? String {
            measuredFingerprint = "\(mac.id)|\(address)|\(interface)|\(route["gateway"] as? String ?? "direct")"
            let tcp = inspection["tcp_connect_ms"] as? Double ?? 0
            measuredDescription = "\(interface) · \(route["tunnel"] as? Bool == true ? "tunnel to target" : "route to target") · TCP \(String(format: "%.1f", tcp)) ms"
        } else { measuredDescription = response["error"] as? String ?? "The target route could not be identified." }
        guard settings.enabled, !settings.paused else { return }
        let previousNetwork = localNetworkFingerprint
        let localNetwork = response["local_network"] as? [String: Any] ?? [:]
        localNetworkFingerprint = localNetwork["fingerprint"] as? String
        let previousRoute = routeFingerprint
        routeFingerprint = measuredFingerprint; routeDescription = measuredDescription
        if previousRoute != routeFingerprint || previousNetwork != localNetworkFingerprint { firstProbeAt = nil }
        if success && offlineCooling { offlineCooling = false; policyState = nil }
        nextProbeAt = now + (offlineCooling ? 60 : 3)
        reachable = success
        var sample: [String: Any] = ["observed_at_ms": UInt64(now * 1000), "status": success ? "rfb_ready" : "connect_failed"]
        if let tcp = inspection["tcp_connect_ms"] { sample["tcp_connect_ms"] = tcp }
        if let greeting = inspection["rfb_greeting_ms"] { sample["rfb_greeting_ms"] = greeting }
        latestProbe = sample
        let healthy = success && (inspection["tcp_connect_ms"] as? Double ?? .infinity) <= 20
            && (inspection["rfb_greeting_ms"] as? Double ?? .infinity) <= 40
        if !healthy { firstProbeAt = nil }
        else if firstProbeAt == nil { firstProbeAt = now }
        let interface = route["interface"] as? String ?? ""
        let type = path?.availableInterfaces.first { $0.name == interface }?.type
        let transport: String
        switch type { case .wifi: transport = "wifi"; case .wiredEthernet: transport = "ethernet"; case .cellular: transport = "cellular"; default: transport = route["tunnel"] as? Bool == true ? "other" : "unknown" }
        let vpn: String = (route["tunnel"] as? Bool).map { $0 ? "present" : "absent" } ?? "unknown"
        // Keep previously saved target-route preferences working while new setup
        // identifies the local network independently of the remote Mac.
        let home = [routeFingerprint, localNetworkFingerprint].compactMap { $0 }.contains { settings.homeRoutes.contains($0) }
        var context: [String: Any] = ["trusted_home_baseline": home,
                                     "allow_high_performance_override": settings.allowVPN || settings.preference == "high_performance",
                                     "high_performance_supported": settings.highPerformanceConfirmed && settings.preference != "standard" && !crashFallback,
                                     "transport": transport, "vpn": vpn]
        if let routeFingerprint { context["route_identity"] = routeFingerprint + "|" + (localNetworkFingerprint ?? "unknown-local-network") }
        var request: [String: Any] = ["now_ms": UInt64(now * 1000), "context": context, "probes": [sample]]
        if let policyState { request["state"] = policyState }
        guard let data = try? JSONSerialization.data(withJSONObject: request), let json = String(data: data, encoding: .utf8) else { return }
        // Keep a single probe/evaluation in flight so delayed callbacks cannot reorder samples.
        probeBusy = true
        let epoch = generation
        cli.run(["network-evaluate", json], timeout: 3) { [weak self] result in
            guard let self else { return }; self.probeBusy = false
            guard !self.stopped, epoch == self.generation, self.settings.enabled, !self.settings.paused else { return }
            guard case .success(let data) = result,
                  let evaluation = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mode = evaluation["recommended_mode"] as? String,
                  ["standard", "high_performance"].contains(mode) else {
                self.pauseForAttention("Evaluation failed", "Automatic actions stopped because the network policy returned an invalid response."); return
            }
            self.policyState = evaluation["state"] as? [String: Any]
            self.recommendation = mode
            if evaluation["action"] as? String == "stop_retrying" {
                self.offlineCooling = true; self.nextProbeAt = self.now + 60
            } else if let delay = evaluation["retry_after_ms"] as? Double {
                self.nextProbeAt = max(self.nextProbeAt, self.now + delay / 1000)
            }
            let reason = Self.describeReason(evaluation["reason"] as? String ?? "")
            if !AppleSession.isTrusted { self.refreshIdleState(); return }
            let displayMode = mode == "high_performance" ? "High Performance" : "Standard"
            let detail = "\(self.routeDescription). \(reason)" + (self.sessionIssue.map { " \($0)" } ?? "")
            self.publish(self.sessionConnected ? "\(displayMode) recommended" : "\(displayMode) · \(home ? "home path" : "away / unknown path")", detail)
            self.considerAction(mac: mac, home: home)
        }
    }
    private func considerAction(mac: SavedMac, home: Bool) {
        guard reachable, path?.status == .satisfied, !launchBusy, AppleSession.isTrusted, now - lastLaunchAt >= 30 else { return }
        if sessionConnected, recommendation != requestedMode {
            reconnect(mac, mode: recommendation)
        } else if !sessionRequested, settings.autoConnect, home,
                  now - (firstProbeAt ?? now) >= 35 {
            launch(mac, mode: recommendation) { _ in }
        }
    }
    func connect(_ connection: SavedMac, completion: @escaping (Result<Data, CLIError>) -> Void) {
        guard settings.enabled, connection.id == settings.targetID else {
            cli.run(["connect", connection.id], completion: completion); return
        }
        guard !launchBusy else { completion(.failure(CLIError(message: "A connection change is already in progress."))); return }
        // An explicit Connect resumes a deliberately paused automation target.
        settings.paused = false; save(); launches = 0
        let mode = settings.preference == "high_performance" && settings.highPerformanceConfirmed ? "high_performance" : settings.preference == "standard" ? "standard" : recommendation
        if sessionConnected {
            completion(.failure(CLIError(message: "The managed session is already open. Use its existing window."))); return
        }
        guard !sessionRequested else {
            completion(.failure(CLIError(message: "Complete or cancel the existing Screen Sharing connection first. Pause and resume automation to retry."))); return
        }
        launch(connection, mode: mode, completion: completion)
    }
    private func launch(_ mac: SavedMac, mode: String, completion: @escaping (Result<Data, CLIError>) -> Void) {
        guard launches < 3 else {
            pauseForAttention("Reconnect limit reached", "Three launches were attempted. Check Screen Sharing, then Resume to try again.")
            completion(.failure(CLIError(message: "Automatic reconnect limit reached."))); return
        }
        launchBusy = true; sessionRequested = true; sessionConnected = false; requestedMode = mode
        sessionIssue = nil
        launches += 1; lastLaunchAt = now
        let epoch = generation
        publish("Opening \(mode == "high_performance" ? "High Performance" : "Standard")…", "Apple handles authentication. The requested mode is not yet confirmed.")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.prepare(for: mac, mode: mode)
            DispatchQueue.main.async { [self] in
                guard !self.stopped, self.generation == epoch else {
                    self.launchBusy = false; self.sessionRequested = false
                    if !self.stopped { self.refreshIdleState() }
                    completion(.failure(CLIError(message: "Connection cancelled."))); return
                }
                self.cli.run(["connect-mode", mac.id, mode]) { [weak self] result in
                    guard let self else { return }; self.launchBusy = false
                    guard !self.stopped, self.generation == epoch else {
                        if !self.stopped { self.refreshIdleState() }
                        completion(result); return
                    }
                    if case .failure(let error) = result {
                        self.sessionRequested = false
                        self.pauseForAttention("Connection failed", error.message)
                    } else if !AppleSession.isTrusted {
                        self.pauseForAttention("Opened without supervision", "Enable Accessibility in Settings for full screen and automatic reconnects.")
                    } else {
                        self.publish("Waiting for Screen Sharing", "Sign in if prompted. MacLink will manage only a new window matching this target’s connection document.")
                    }
                    completion(result)
                }
            }
        }
    }
    private func observeSession() {
        guard !observationBusy else { return }
        observationBusy = true
        let epoch = generation, fullscreen = settings.fullScreen, operation = intent
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let observation = self.session.observe(fullscreen: fullscreen, shouldAct: { operation.isActive })
            let issue = self.session.lastIssue
            DispatchQueue.main.async {
                self.observationBusy = false
                guard !self.stopped, self.generation == epoch, !self.launchBusy else { return }
                switch observation {
                case .connected: self.sessionConnected = true; self.sessionIssue = issue
                case .waiting: break
                case .closed:
                    self.sessionRequested = false; self.sessionConnected = false
                    self.pauseForAttention("Session closed · paused", "Closing the managed window pauses automation so it does not reopen against your wishes.")
                case .appExited:
                    self.sessionRequested = false; self.sessionConnected = false
                    self.crashFallback = true; self.policyState = nil; self.recommendation = "standard"
                    self.pauseForAttention("Viewer exited · paused", "Resume or Connect when you are ready. The next automatic attempt uses Standard; MacLink cannot distinguish a crash from Quit.")
                case .unavailable: self.pauseForAttention("Accessibility unavailable", "Restore MacLink’s Accessibility permission to supervise the session.")
                case .ambiguous:
                    if self.requestedMode == "high_performance" { self.crashFallback = true; self.recommendation = "standard"; self.policyState = nil }
                    self.pauseForAttention("Session needs attention", (issue ?? "Could not identify one new matching Screen Sharing window.") + " Finish signing in, or close this connection and Resume to try again.")
                case .closing: break
                }
            }
        }
    }
    private func reconnect(_ mac: SavedMac, mode: String) {
        guard launches < 3 else { pauseForAttention("Switch limit reached", "Resume to allow another connection attempt."); return }
        launchBusy = true
        let epoch = generation, operation = intent
        publish("Switching to \(mode == "high_performance" ? "High Performance" : "Standard")…", "Reconnecting the matching Screen Sharing session after a sustained path change.")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let closed = self.session.closeOwnedWindow(shouldAct: { operation.isActive })
            DispatchQueue.main.async {
                guard !self.stopped, epoch == self.generation else {
                    self.launchBusy = false
                    if !self.stopped { self.refreshIdleState() }; return
                }
                guard closed else { self.launchBusy = false; self.pauseForAttention("Couldn’t switch safely", "The session window could not be closed. Use Screen Sharing to reconnect manually."); return }
                self.waitForClose(mac, mode: mode, epoch: epoch, attempts: 0)
            }
        }
    }
    private func waitForClose(_ mac: SavedMac, mode: String, epoch: Int, attempts: Int) {
        sessionQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let closed = self.session.pollOwnedWindowClosed()
            DispatchQueue.main.async {
                guard !self.stopped, self.generation == epoch else {
                    self.launchBusy = false
                    if closed { self.sessionRequested = false; self.sessionConnected = false }
                    if !self.stopped { self.refreshIdleState() }; return
                }
                if closed {
                    self.launchBusy = false; self.sessionRequested = false; self.sessionConnected = false
                    self.launch(mac, mode: mode) { _ in }
                } else if attempts < 15 { self.waitForClose(mac, mode: mode, epoch: epoch, attempts: attempts + 1) }
                else { self.launchBusy = false; self.pauseForAttention("Close the connection to continue", "Screen Sharing kept the old window open. MacLink will not open a duplicate.") }
            }
        }
    }
    private func pauseForAttention(_ title: String, _ detail: String) {
        intent.cancel(); intent = AutomationIntent()
        settings.paused = true; save(); generation += 1
        publish(title, detail)
    }
    func showSettings(connections: [SavedMac], parentWindow: NSWindow?) {
        self.connections = connections
        if let controller = settingsWindow, controller.window?.isVisible == true {
            controller.updateConnections(connections)
            NSApp.activate(ignoringOtherApps: true); controller.window?.makeKeyAndOrderFront(nil); return
        }
        let controller = AutomationSettingsController(settings: settings, connections: connections)
        settingsWindow = controller
        controller.onCheckHome = { [weak self, weak controller] request in
            guard let self, let controller else { return }
            let networkEpoch = self.networkGeneration
            // Separate from ongoing remote probes: an asleep Mac, slow DNS or
            // occupied probe slot must never prevent local home-network setup.
            self.cli.run(["home-network"], timeout: 4) { [weak self, weak controller] result in
                guard let self, let controller, !self.stopped else { return }
                guard self.networkGeneration == networkEpoch else {
                    controller.completeHomeCheck(request: request, description: "The network changed during detection. Try Detect Network again.", fingerprint: nil)
                    return
                }
                switch result {
                case .failure(let error):
                    controller.completeHomeCheck(request: request, description: "Couldn’t detect this network. \(error.message)", fingerprint: nil)
                case .success(let data):
                    guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let description = response["description"] as? String else {
                        controller.completeHomeCheck(request: request, description: "The network check returned an invalid result. Try again.", fingerprint: nil); return
                    }
                    controller.completeHomeCheck(request: request, description: description, fingerprint: response["fingerprint"] as? String)
                }
            }
        }
        controller.onSave = { [weak self, weak controller] updated, launchAtLogin in
            guard let self else { return }
            let changedTarget = updated.targetID != self.settings.targetID
            self.settings = updated; self.save(); self.invalidateEvidence()
            self.launches = 0; self.crashFallback = false
            if changedTarget { self.sessionRequested = false; self.sessionConnected = false; self.requestedMode = nil }
            controller?.close(); self.refreshIdleState(); self.tick()
            // Login registration is independent of saving home preferences.
            do {
                let status = SMAppService.mainApp.status
                if launchAtLogin && status != .enabled && status != .requiresApproval { try SMAppService.mainApp.register() }
                else if !launchAtLogin && (status == .enabled || status == .requiresApproval) { try SMAppService.mainApp.unregister() }
            } catch {
                let alert = NSAlert(); alert.messageText = "Settings saved; login launch couldn’t be updated"
                alert.informativeText = "Your home networks and automation settings were saved. \(error.localizedDescription)"
                alert.runModal()
            }
        }
        controller.showWindow(nil); controller.window?.center(); NSApp.activate(ignoringOtherApps: true)
    }
    private static func describeReason(_ reason: String) -> String {
        switch reason {
        case "awaiting_healthy_measurements": return "Watching for 30 seconds of stable connection checks before an upgrade."
        case "sustained_healthy_measurements": return "Connection checks are stable. Available video bandwidth is still unknown."
        case "sustained_adverse_measurements", "awaiting_fallback_dwell": return "Connection checks are slow or uneven; Standard is the conservative choice."
        case "route_changed": return "The path changed; rebuilding connection evidence."
        case "high_performance_unsupported": return "High Performance is disabled or has not been confirmed in Settings."
        case "tunnel_override_required": return "VPN paths use Standard unless allowed in Settings."
        case "explicit_approval_required": return "This path is not marked as home; using Standard."
        case "unknown_target_route": return "The target route is uncertain; using Standard."
        case "retry_budget_exhausted": return "The Mac is unavailable. Checks slow to once a minute."
        case "switch_budget_exhausted": return "Repeated changes stopped further upgrades for this session."
        default: return "Evaluating target reachability. Bandwidth and video latency are not measured."
        }
    }
}
