import AppKit

/// Application workflow for Linux desktops. Platform effects are supplied at
/// construction; the Rust model owns legal lifecycle transitions.
final class LinuxConnectionWorkflow {
    private let tunnels: any TunnelRunning
    private let client: any LinuxVNCConnecting
    private let scheduler: any ConnectionScheduling
    private let executable: () throws -> URL
    private let screenArguments: () -> [String]
    private let extendsBesideCamera: () -> Bool
    private let makeViewer: (SavedMac, UInt64, Bool) -> any LinuxViewerPresenting
    private let prompt: LinuxSignInPrompt
    private let activate: () -> Void
    private let defaults: UserDefaults
    private var generation: UInt64 = 0
    private var attempts: [String: LinuxConnectionAttempt] = [:]
    private(set) var vncViewers: [String: any LinuxViewerPresenting] = [:]
    var onStatus: ((String, String, Bool, Bool) -> Void)?
    var onAction: ((String) -> Void)?
    var onChange: (() -> Void)?
    var onShowConnections: (() -> Void)?
    var linuxShowsFooter: Bool {
        get { defaults.object(forKey: "vnc.showDiagnosticBar") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "vnc.showDiagnosticBar") }
    }
    init(tunnels: any TunnelRunning = SSHTunnels(), client: any LinuxVNCConnecting = RustLinuxVNCClient(),
         scheduler: any ConnectionScheduling = MainConnectionScheduler(), defaults: UserDefaults = .standard,
         executable: @escaping () throws -> URL, screenArguments: @escaping () -> [String] = { [] },
         extendsBesideCamera: @escaping () -> Bool = { false },
         makeViewer: @escaping (SavedMac, UInt64, Bool) -> any LinuxViewerPresenting = {
             VNCViewerWindow(name: $0.name, connectionID: $0.id, sessionID: $1, showsDiagnosticBar: $2)
         }, prompt: @escaping LinuxSignInPrompt = { VNCSignIn.prompt(name: $0, username: $1, detail: $2, completion: $3) },
         activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) }) {
        self.tunnels = tunnels; self.client = client; self.scheduler = scheduler; self.defaults = defaults
        self.executable = executable; self.screenArguments = screenArguments; self.extendsBesideCamera = extendsBesideCamera
        self.makeViewer = makeViewer; self.prompt = prompt; self.activate = activate
        tunnels.onEvent = { [weak self] in self?.tunnelEvent($0, $1) }
        tunnels.onExit = { [weak self] in self?.tunnelExited($0, $1, $2) }
    }
    func stop() {
        for attempt in attempts.values { attempt.apply(.close) }
        for viewer in vncViewers.values { viewer.onClose = nil; client.close(viewer.sessionID); viewer.close() }
        vncViewers.removeAll()
        tunnels.stopAll(wait: 2)
    }
    private func setStatus(_ title: String, _ detail: String, error: Bool = false, success: Bool = false) {
        onStatus?(title, detail, error, success)
    }
    private func refreshStatusMenu() { onChange?() }
    private func showConnections() { onShowConnections?() }
    private func retrySignIn(_ mac: SavedMac, attempt: LinuxConnectionAttempt) {
        guard attempts[mac.id] === attempt, attempt.apply(.retryRequested) == .askForSignIn else { return }
        // Reuse the one prompt path after the explicit retry transition.
        askForSignIn(mac, attempt: attempt)
    }
    func connect(_ mac: SavedMac) {
        guard let target = mac.ssh?.target else { return }
        if tunnels.isRunning(mac.id) {
            setStatus("Already connected through SSH", "\(mac.name)’s SSH tunnel is open. Close its viewer window to end it.", success: true)
            return
        }
        if let viewer = vncViewers[mac.id], !viewer.isClosed {
            viewer.showWindow(nil)
            return
        }
        do {
            generation &+= 1
            attempts[mac.id] = LinuxConnectionAttempt(generation: generation)
            // Mooring's own viewer connects; the tunnel waits up to 10 minutes
            // for sign-in and lingers 5 minutes between tries.
            let extra = ["--no-viewer", "--wait-seconds", "600", "--idle-seconds", "300"] + screenArguments()
            try tunnels.open(mac, executable: executable(), extraArguments: extra)
        } catch {
            attempts[mac.id]?.apply(.close)
            setStatus("Couldn’t start SSH", error.localizedDescription, error: true)
            return
        }
        onAction?("Connecting to \(mac.name.prefix(40)) through SSH…")
        setStatus("Connecting through SSH…", "Checking \(target) with your SSH keys and agent. Mooring never asks for a password.")
        refreshStatusMenu()
    }

    private func tunnelEvent(_ mac: SavedMac, _ event: TunnelEvent) {
        guard let attempt = attempts[mac.id], attempt.phase != .closed else { return }
        switch event {
        case .retry(let error):
            setStatus("Retrying SSH…", error?.message ?? "The SSH connection dropped during setup.")
        case .ready(let ready):
            guard attempt.apply(.tunnelReady, port: ready.localPort) == .waitForDesktop else { return }
            attempt.route = ready.check
            setStatus("Reached \(mac.name) through SSH", "Checking whether its desktop is locked before signing in…")
            scheduler.after(2.5) { [weak self, weak attempt] in
                guard let self, let attempt, self.attempts[mac.id] === attempt else { return }
                self.presentVNCSignIn(mac)
            }
        case .desktop(let desktop):
            attempt.desktop = desktop
            vncViewers[mac.id]?.showDesktop(desktop.title)
            if attempt.phase == .waitingForDesktop { presentVNCSignIn(mac); return }
            onAction?("\(mac.name.prefix(40)): \(desktop.title)")
            setStatus("\(mac.name): \(desktop.title)", desktop.message, success: desktop.lock == "unlocked")
        case .screen(let screen):
            let width = screen.width ?? 0, height = screen.height ?? 0
            switch screen.state {
            case "ready":
                onAction?("\(mac.name.prefix(40)): screen matched to this Mac")
                let resizedX11 = screen.kind == "x11_resize"
                if resizedX11 {
                    attempt.pixelsPerPoint = 1
                    vncViewers[mac.id]?.remotePixelsPerPoint = 1
                }
                if attempt.phase != .waitingForDesktop {
                    if resizedX11 {
                        let previous = screen.previous ?? "its own size"
                        setStatus("\(mac.name): screen matched", "Showing \(mac.name)’s X11 desktop at \(width)×\(height), sized to this Mac. It returns to \(previous) when you disconnect.", success: true)
                    } else {
                        setStatus("\(mac.name): screen matched", "Showing \(mac.name) on a \(width)×\(height) virtual screen sized to this Mac. Its own screen comes back when you disconnect.", success: true)
                    }
                }
            case "failed":
                setStatus("Showing \(mac.name)’s own screen", screen.error?.message ?? "Mooring couldn’t add a virtual screen there.")
            case "restore_unconfirmed":
                setStatus("Check \(mac.name)’s screen", "Mooring couldn’t confirm that \(mac.name)’s own screen was restored. It restores itself within about 20 seconds once the connection is gone.", error: true)
            default:
                return
            }
        case .failed(let error):
            attempt.terminalEventReceived = true
            attempt.apply(.close)
            vncViewers[mac.id]?.end("The SSH tunnel closed.")
            onAction?("SSH connection failed")
            setStatus("Couldn’t connect through SSH", error?.message ?? "The SSH tunnel closed.", error: true)
            showConnections()
        case .closed(let reason):
            attempt.terminalEventReceived = true
            attempt.apply(.close)
            if let viewer = vncViewers[mac.id], !viewer.isClosed, viewer.sessionID != 0 { viewer.end("The SSH tunnel closed.") }
            onAction?("SSH tunnel closed")
            let detail = reason == "no_viewer"
                ? "No sign-in started in time, so the tunnel closed."
                : "The SSH tunnel to \(mac.name) has closed."
            setStatus("SSH tunnel closed", detail)
        default: return
        }
        refreshStatusMenu()
    }

    /// Sign in to the VNC server once the tunnel is ready. Rust decides what to
    /// ask for, from the tunnel's check, and whether another attempt is
    /// allowed; a password goes straight to Rust, which wipes the buffer
    /// before returning. A server with no VNC password, reached through SSH
    /// on its own loopback address, opens without a prompt: the SSH key is
    /// the sign-in.
    private func presentVNCSignIn(_ mac: SavedMac) {
        guard let attempt = attempts[mac.id], attempt.apply(.desktopReadyOrTimedOut) == .askForSignIn, tunnels.isRunning(mac.id) else { return }
        askForSignIn(mac, attempt: attempt)
    }
    private func askForSignIn(_ mac: SavedMac, attempt: LinuxConnectionAttempt) {
        guard let route = attempt.route, tunnels.isRunning(mac.id) else { return }
        let port = attempt.port
        let (planned, needs) = client.signInNeeds(route)
        // Nothing to ask, or nothing Mooring can use: Rust's session says why.
        if planned != 0 || needs == Int32(ML_VNC_NEEDS_NOTHING) {
            let note = planned == 0
                ? "Signing in with your SSH key: this VNC server has no password, and Mooring reaches it only through SSH, on its own loopback address."
                : "Mooring can’t sign in to this VNC server; the viewer says why."
            startVNC(mac, port: port, remoteHost: route.remoteHost, username: "", password: [], signingIn: note)
            return
        }
        let (allowed, wait, remaining) = client.signInAllowance(mac.id)
        if allowed == Int32(ML_SESSION_RATE_LIMITED) {
            let minutes = max(1, Int((wait + 59_999) / 60_000))
            attempt.apply(.close)
            tunnels.stop(mac.id)
            setStatus("Waiting before another sign-in", "Two sign-ins to \(mac.name) failed in the last 10 minutes, so Mooring waits about \(minutes) more minute\(minutes == 1 ? "" : "s") before another try. You can also sign in at the computer.", error: true)
            refreshStatusMenu()
            return
        }
        let desktop = attempts[mac.id]?.desktop
        let passwordOnly = needs == Int32(ML_VNC_NEEDS_PASSWORD)
        let sshUser = mac.ssh?.target.split(separator: "@", maxSplits: 1).count == 2 ? String(mac.ssh!.target.split(separator: "@")[0]) : nil
        var detail = passwordOnly
            ? "\(mac.name)’s VNC server asks for its own VNC password, not an account. Mooring answers its challenge once, inside SSH, and doesn’t save the password. Only its first 8 characters count."
            : "\(mac.name)’s VNC server asks for an account on that computer. Mooring sends it once, encrypted (RSA-AES) inside SSH, and doesn’t save it."
        if remaining == 1 { detail += "\n\nAfter one more failed sign-in, Mooring waits 10 minutes before another try." }
        if let desktop { detail += "\n\n\(desktop.title): \(desktop.message)" }
        setStatus("Sign in to \(mac.name)", passwordOnly ? "Waiting for the VNC password." : "Waiting for the account name and password.")
        prompt(mac.name, passwordOnly ? nil : sshUser ?? desktop?.sessionUser ?? "", detail) { [weak self] answer in
            guard let self, self.attempts[mac.id] === attempt, attempt.phase == .authenticating else { return }
            guard let answer, self.tunnels.isRunning(mac.id) else {
                attempt.apply(.close)
                self.tunnels.stop(mac.id)
                self.setStatus("Sign-in cancelled", "The SSH tunnel to \(mac.name) has been closed.")
                self.refreshStatusMenu()
                return
            }
            self.startVNC(mac, port: port, remoteHost: route.remoteHost, username: answer.username, password: answer.password,
                          signingIn: "Signing in through SSH.")
        }
    }

    /// Start the session. Rust copies `password` and wipes this copy.
    private func startVNC(_ mac: SavedMac, port: UInt16, remoteHost: String, username: String, password: [UInt8], signingIn: String) {
        guard let attempt = attempts[mac.id], attempt.phase == .authenticating else { return }
        let (status, session) = client.open(mac.id, port: port, remoteHost: remoteHost, username: username, password: password)
        guard status == 0, session != 0 else {
            attempt.apply(.close)
            tunnels.stop(mac.id)
            setStatus("Couldn’t start the viewer", String(cString: ml_session_error_string(status)), error: true)
            return
        }
        attempt.apply(.viewerStarted)
        openVNCViewer(mac, session: session, port: port, signingIn: signingIn)
    }

    private func openVNCViewer(_ mac: SavedMac, session: UInt64, port: UInt16, signingIn: String) {
        guard let attempt = attempts[mac.id] else { client.close(session); return }
        if let old = vncViewers[mac.id] { old.onClose = nil; old.close() }
        let viewer = makeViewer(mac, session, linuxShowsFooter)
        viewer.onDiagnosticBarChange = { [weak self] shows in self?.linuxShowsFooter = shows }
        // As from the Mac-to-Mac viewer's Allow ⌘-Tab….
        viewer.onAllowSystemKeys = {
            AccessibilityPermission.request()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
        }
        // The viewer checks the desktop's size before using the camera row.
        viewer.extendsBesideCamera = extendsBesideCamera()
        viewer.remotePixelsPerPoint = attempt.pixelsPerPoint.map { CGFloat($0) }
        if let desktop = attempts[mac.id]?.desktop { viewer.showDesktop(desktop.title) }
        viewer.onClose = { [weak self] in
            guard let self, self.attempts[mac.id] === attempt else { return }
            attempt.apply(.close)
            self.vncViewers[mac.id] = nil
            self.tunnels.stop(mac.id)
        }
        viewer.onSignInRejected = { [weak self, weak viewer] message in
            guard let self, self.attempts[mac.id] === attempt, attempt.phase != .closed else { return }
            viewer?.onClose = nil
            viewer?.close()
            self.vncViewers[mac.id] = nil
            self.setStatus("Sign-in not accepted", message, error: true)
            guard self.tunnels.isRunning(mac.id) else { return }
            attempt.apply(.viewerEnded)
            self.retrySignIn(mac, attempt: attempt)
        }
        viewer.onEnded = { [weak self] message in
            guard let self, self.attempts[mac.id] === attempt, attempt.phase != .closed else { return }
            attempt.apply(.viewerEnded)
            self.setStatus("\(mac.name): session ended", message ?? "The VNC session has ended.")
        }
        viewer.onReconnect = { [weak self] in
            guard let self, self.attempts[mac.id] === attempt else { return }
            if self.tunnels.isRunning(mac.id) {
                self.retrySignIn(mac, attempt: attempt)
            } else {
                self.vncViewers[mac.id]?.onClose = nil
                self.vncViewers[mac.id]?.close()
                self.vncViewers[mac.id] = nil
                self.connect(mac)
            }
        }
        vncViewers[mac.id] = viewer
        onAction?("Viewing \(mac.name.prefix(40))")
        setStatus("Connecting to \(mac.name)…", signingIn + " Closing the viewer closes the tunnel.", success: true)
        viewer.showWindow(nil)
        activate()
        refreshStatusMenu()
    }

    private func tunnelExited(_ mac: SavedMac, _ status: Int32, _ message: String) {
        guard let attempt = attempts[mac.id], !attempt.terminalEventReceived else { return }
        attempt.apply(.close)
        vncViewers[mac.id]?.end(message.isEmpty ? "The SSH tunnel stopped." : message)
        // Exited without a final event, for example the CLI could not start.
        onAction?("SSH tunnel stopped")
        setStatus("SSH tunnel stopped", message.isEmpty ? "The SSH tunnel process exited (\(status))." : message, error: status != 0)
        refreshStatusMenu()
    }


}
