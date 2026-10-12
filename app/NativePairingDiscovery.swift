import Foundation
import Network
import dnssd

/// A Mac nearby that is showing a pairing PIN, found through Bonjour. What it
/// advertises isn't trusted: the PIN exchange proves the Mac, so a false
/// entry can only fail.
struct NativeNearbyMac: Equatable {
    let name: String
    /// Its peer ID, when advertised: says whether this Mac already pairs with it.
    let id: String?
    /// Normalized, the local hostname first, at most ML_ADDRESSES_MAX.
    let addresses: [String]
}

/// Bonjour service type for Macs showing a PIN.
let nativePinService = "_mooring-pair._tcp"

/// Advertises this Mac's pairing listener while a PIN shows: its name, peer
/// ID and addresses. Public `dns_sd` API; stops when released.
final class NativePinAdvert {
    private var service: DNSServiceRef?

    init?(name: String, port: UInt16, peerID: String, addresses: [String]) {
        var entries = ["v=1", "id=" + peerID]
        if let host = addresses.first { entries.append("host=" + host) }
        let others = addresses.dropFirst().joined(separator: ",")
        if !others.isEmpty { entries.append("ip=" + others) }
        var txt = Data()
        for entry in entries {
            let bytes = Data(entry.utf8)
            guard bytes.count <= 255 else { continue }
            txt.append(UInt8(bytes.count)); txt.append(bytes)
        }
        var service: DNSServiceRef?
        let status = txt.withUnsafeBytes { bytes in
            DNSServiceRegister(&service, 0, 0, name, nativePinService, nil, nil, port.bigEndian,
                               UInt16(bytes.count), bytes.baseAddress, { _, _, _, _, _, _, _ in }, nil)
        }
        guard status == kDNSServiceErr_NoError, let service else { return nil }
        guard DNSServiceSetDispatchQueue(service, .main) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(service); return nil
        }
        self.service = service
    }
    func stop() {
        if let service { DNSServiceRefDeallocate(service) }
        service = nil
    }
    deinit { stop() }
}

/// Lists the Macs nearby that are showing a PIN, while it runs.
final class NativePinBrowser {
    /// The Macs found, in name order, or nil if looking failed (for example
    /// with Local Network access turned off for Mooring).
    var onChange: (([NativeNearbyMac]?) -> Void)?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: nativePinService, domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.onChange?(results.compactMap(Self.nearby).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.onChange?(nil) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }
    func stop() { browser?.cancel(); browser = nil }
    deinit { stop() }

    private static func nearby(_ result: NWBrowser.Result) -> NativeNearbyMac? {
        guard case .service(let name, _, _, _) = result.endpoint, case .bonjour(let txt) = result.metadata else { return nil }
        var addresses: [String] = []
        for entry in [txt["host"] ?? ""] + (txt["ip"] ?? "").split(separator: ",").map(String.init) {
            guard let address = NativePairingCode.normalizedAddress(entry), !addresses.contains(address) else { continue }
            addresses.append(address)
        }
        guard !addresses.isEmpty else { return nil }
        let id = txt["id"].flatMap { $0.count == 64 && $0.allSatisfy(\.isHexDigit) ? $0.lowercased() : nil }
        return NativeNearbyMac(name: String(name.prefix(160)), id: id, addresses: Array(addresses.prefix(Int(ML_ADDRESSES_MAX))))
    }
}
