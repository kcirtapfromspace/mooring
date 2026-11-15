import AppKit
import IOKit.pwr_mgt
import ApplicationServices
import SystemConfiguration
import CoreVideo
import CryptoKit

// Application workflow implementation. Invariants and wire validation live in Rust.
extension NativeSessionCoordinator {
    func pairingCode() throws -> NativePairingCode {
        guard let identity = hostIdentity, let listener, isSharing else {
            throw NativeSessionError(message: "Start sharing before copying a pairing code.")
        }
        let localName = SCDynamicStoreCopyLocalHostName(nil) as String? ?? "localhost"
        return try NativePairingCode.forHost(address: localName + ".local", computerName: NativeDeviceKey.computerName, identity: identity,
                                             oneTimeSecret: listener.newPairingSecret(), alternates: NativePairingCode.localAddresses())
    }
    func copyPairingCode() {
        do {
            let code = try pairingCode().encoded()
            // The code carries a one-time pairing secret. The nspasteboard.org
            // concealed marker asks clipboard managers not to record or display it.
            let item = NSPasteboardItem()
            item.setString(code, forType: .string)
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item])
            shareWindow?.detail.stringValue = "Code copied. Paste into Pair a Mac on your other Mac within 10 minutes, "
                + "while sharing stays on. It pairs one Mac, once; copying another code replaces it."
        } catch { refreshShare(error.localizedDescription) }
    }
    func resetPairing() {
        stopSharing(reason: "Pairing reset requested.")
        // A PIN on screen belongs to the identity being replaced.
        pinWindow?.close(); stopPIN()
        do {
            // Approvals first: if they can't be cleared, the old identity stays.
            try deviceStore.reset()
            let identity = try NativeHostIdentity.create(); try keychain.saveHostIdentity(identity); hostIdentity = identity
            refreshShare("No Mac can connect until it pairs again. Start sharing and copy a new code.")
        } catch { refreshShare(error.localizedDescription) }
    }

    /// Shows a PIN another Mac can pair with in Pair a Mac, whether or not this
    /// Mac is sharing, and while another Mac is viewing it.
    func showPIN() {
        if pinWindow == nil {
            let controller = NativePinWindow(); pinWindow = controller
            controller.onNewPIN = { [weak self] in self?.makePIN() }
            controller.onClose = { [weak self] in self?.stopPIN() }
        }
        pinWindow?.showWindow(nil); pinWindow?.window?.center(); NSApp.activate(ignoringOtherApps: true)
        if pinToken == nil { makePIN() }
    }
    /// A new PIN, replacing any earlier one, on a pairing listener started if needed.
    func makePIN() {
        do {
            let listener: NativeTransport
            if let pinListener, pinToken?.isActive == true {
                listener = pinListener
            } else {
                stopPIN()
                listener = try io.listenForPIN(try preparedHostIdentity(), deviceStore)
                let token = NativeRunToken()
                pinListener = listener; pinToken = token
                acceptPINs(listener, token: token)
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPIN() }
                RunLoop.main.add(timer, forMode: .common); pinTimer = timer
            }
            let localName = (SCDynamicStoreCopyLocalHostName(nil) as String? ?? "localhost") + ".local"
            let others = NativePairingCode.localAddresses()
            let pin = try listener.newPIN(address: localName, computerName: NativeDeviceKey.computerName, alternates: others)
            pinWindow?.show(pin: pin)
            pinAdvert?.stop()
            pinAdvert = hostIdentity.flatMap { identity in
                NativePinAdvert(name: NativeDeviceKey.computerName, port: NativeTransport.pinPort,
                                peerID: SHA256.hash(data: identity.publicKey).map { String(format: "%02x", $0) }.joined(),
                                addresses: [localName] + others)
            }
            if pinAdvert == nil { NativeLog.session.error("couldn't advertise the PIN nearby; pair by address instead") }
            NativeLog.session.notice("showing a pairing PIN")
            refreshPIN()
        } catch {
            stopPIN()
            pinWindow?.showProblem(error.localizedDescription)
        }
    }
    /// Takes PIN attempts until the window closes. Each that didn't pair
    /// shows in the window as a try used.
    func acceptPINs(_ listener: NativeTransport, token: NativeRunToken) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while token.isActive {
                do {
                    guard let device = try listener.acceptPIN() else { continue }
                    DispatchQueue.main.async { self?.pinPaired(device, token: token) }
                } catch {
                    guard token.isActive else { return }
                    DispatchQueue.main.async { self?.refreshPIN() }
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
        }
    }
    func pinPaired(_ device: (id: String, name: String), token: NativeRunToken) {
        guard token.isActive, pinToken === token else { return }
        pinAdvert?.stop(); pinAdvert = nil
        NativeLog.session.notice("a Mac paired with this Mac's PIN")
        pinWindow?.showPaired(MooringPrivacy.name(device.name, id: device.id), sharing: isSharing)
        refreshShare()
    }
    /// Once a second: how long the PIN works, and its tries. A PIN that
    /// stopped working is no longer advertised.
    func refreshPIN() {
        guard let state = pinListener?.pinState else { return }
        if state.active == 0 { pinAdvert?.stop(); pinAdvert = nil }
        pinWindow?.update(state)
    }
    /// A PIN never works while nobody can see it: locked, asleep or another user.
    func endPINForPrivacy() {
        guard pinToken != nil else { return }
        stopPIN()
        pinWindow?.showProblem("The PIN stopped when this Mac locked or slept. Make a new one when you're back.")
    }
    func stopPIN() {
        pinToken?.cancel(); pinToken = nil
        pinListener?.clearPIN(); pinListener?.close(); pinListener = nil
        pinAdvert?.stop(); pinAdvert = nil
        pinTimer?.invalidate(); pinTimer = nil
    }

    /// Viewer: pairs with a PIN at `addresses`. Only pairs: a session on
    /// screen stays as it is. A pairing that finishes after the window closed
    /// is still saved, since the other Mac approved it.
    func pairWithPIN(_ pin: String, addresses: [String]) {
        guard pinPairing == nil else { return }
        var candidates: [String] = []
        for entry in addresses {
            guard let address = NativePairingCode.normalizedAddress(entry) else {
                pairWindow?.showError("Enter a hostname or IP address without a port."); return
            }
            if !candidates.contains(address) { candidates.append(address) }
        }
        let deviceKey: NativeDeviceKey
        do { deviceKey = try NativeDeviceKey.create() } catch { pairWindow?.showError(error.localizedDescription); return }
        let token = NativeRunToken(); pinPairing = token
        pairWindow?.setBusy(true); pairWindow?.showError("")
        let addresses = Array(candidates.prefix(Int(ML_ADDRESSES_MAX)))
        let pairIO = io.pairWithPIN
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try pairIO(pin, addresses, deviceKey) }
            DispatchQueue.main.async {
                guard let self, self.pinPairing === token else { return }
                self.pinPairing = nil
                self.pairWindow?.setBusy(false)
                switch result {
                case .success(let (code, used)):
                    do {
                        try self.keychain.savePeerCode(code, deviceKey: deviceKey)
                        let tried = [used] + addresses.filter { $0 != used }
                        let peer = (try? self.peerStore.remember(code, tried: tried)) ?? NativePeer(code: code, address: used)
                        self.peers = (try? self.peerStore.load()) ?? self.peers
                        MooringPrivacy.register(name: peer.name, id: peer.id, addresses: peer.addresses)
                        NativeLog.session.notice("paired with a PIN by address \((addresses.firstIndex(of: used) ?? 0) + 1) of \(addresses.count)")
                        self.pairWindow?.showPaired(MooringPrivacy.name(peer.name, id: peer.id), peerID: peer.id)
                    } catch {
                        self.pairWindow?.showError("The other Mac approved this Mac, but it couldn’t save the pairing: "
                            + error.localizedDescription + " Show a new PIN there and try again.")
                    }
                case .failure(let error):
                    self.pairWindow?.showError(Self.pinFailure(error))
                }
            }
        }
    }
    static func pinFailure(_ error: Error) -> String {
        switch (error as? NativeSessionError)?.status ?? 0 {
        case Int32(ML_SESSION_UNAVAILABLE):
            return "That Mac isn’t showing a PIN. On it, open Mooring → Share this Mac → Show PIN."
        case Int32(ML_SESSION_AUTH):
            return "That PIN didn’t work. Check it on the other Mac and try again. A PIN allows \(ML_PIN_TRIES) tries, then make a new one."
        case Int32(ML_SESSION_TIMEOUT), Int32(ML_SESSION_IO):
            return "That Mac didn’t answer. Check that both Macs are on the same network, or enter its address."
        case Int32(ML_SESSION_CLOSED), Int32(ML_SESSION_PROTOCOL):
            return "That Mac runs a different Mooring version. Update both Macs, then try again."
        default:
            return error.localizedDescription
        }
    }

    /// Whether the Mac on `transport` may still connect: its key is still
    /// listed, or it used the old code and that still works.
    func stillAllowed(_ transport: NativeTransport) -> Bool {
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
            endHost(reason: "The viewing Mac was removed. Pair again with a new code.", revoking: true)
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

    /// Pairing works while another Mac is on screen: that session stays up
    /// until the new Mac connects, and a failed pairing leaves it as it was.
    func showConnect() {
        if pairWindow == nil {
            let controller = NativePairWindow(); pairWindow = controller
            controller.onConnect = { [weak self] rawCode, override in
                guard let self else { return }
                do {
                    let code = try NativePairingCode.parse(rawCode)
                    // An address typed in is tried first, with every address in the code.
                    let address = override.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.connect(code: code, addresses: address.isEmpty ? code.addresses : [address] + code.addresses, pairing: true)
                } catch { self.pairWindow?.showError(error.localizedDescription) }
            }
            controller.onPairPIN = { [weak self] pin, addresses in self?.pairWithPIN(pin, addresses: addresses) }
            controller.onConnectPaired = { [weak self] peerID in
                self?.pairWindow?.close(); self?.connect(peerID: peerID)
            }
            controller.onClose = { [weak self] in
                self?.pinBrowser.stop()
                if self?.connecting?.pairing == true { self?.cancelConnect() }
            }
            pinBrowser.onChange = { [weak self] found in
                guard let self else { return }
                self.pairWindow?.setNearby(found, pairedIDs: Set(self.peers.map(\.id)))
            }
        }
        pairWindow?.setNearby([], pairedIDs: Set(peers.map(\.id)))
        pinBrowser.start()
        pairWindow?.setBusy(pinPairing != nil); pairWindow?.showError("")
        pairWindow?.setPrivacy(MooringPrivacy.isEnabled)
        pairWindow?.setViewing(connectedPeerID.map { id in
            MooringPrivacy.name(peers.first { $0.id == id }?.name ?? "The Mac on screen", id: id)
        })
        pairWindow?.showWindow(nil); pairWindow?.window?.center(); NSApp.activate(ignoringOtherApps: true)
    }
    /// Brings the session already showing `peerID` forward; false when none is.
}
