import Foundation
import Security
import SystemConfiguration

struct NativeSessionError: LocalizedError {
    let message: String
    /// The Rust status when the error came from the session library, else 0.
    var status: Int32 = 0
    var errorDescription: String? { message }
    /// Authentication failures mean the pairing changed; retrying cannot help.
    var isAuthenticationFailure: Bool { status == Int32(ML_SESSION_AUTH) }
    /// The other Mac answered, but Mooring isn't sharing there.
    var isNotSharing: Bool { status == Int32(ML_SESSION_UNAVAILABLE) }
}

/// The sharing Mac's Noise identity and pairing secret, stored only in Keychain.
struct NativeHostIdentity: Codable {
    let privateKey: Data
    let publicKey: Data
    let secret: Data
    /// Set once this identity keeps a list of approved Macs. Its old code is
    /// then never accepted from scratch again, even if the list is lost.
    var listsDevices: Bool?

    static func create() throws -> Self {
        var privateKey = [UInt8](repeating: 0, count: 32)
        var publicKey = [UInt8](repeating: 0, count: 32)
        var secret = [UInt8](repeating: 0, count: 32)
        try NativeTransport.check(ml_session_generate_identity(&privateKey, &publicKey, &secret))
        return Self(privateKey: Data(privateKey), publicKey: Data(publicKey), secret: Data(secret), listsDevices: true)
    }
    func validate() throws {
        guard privateKey.count == 32, publicKey.count == 32, secret.count == 32 else {
            throw NativeSessionError(message: "The saved pairing identity is invalid. Reset pairing on this Mac.")
        }
    }
}

/// This Mac's own key, which a sharing Mac approves once and then knows it
/// by. Only the private half is kept, in Keychain; Rust derives the rest.
struct NativeDeviceKey {
    let privateKey: Data

    static func create() throws -> Self {
        var privateKey = [UInt8](repeating: 0, count: 32)
        var publicKey = [UInt8](repeating: 0, count: 32)
        var unused = [UInt8](repeating: 0, count: 32)
        try NativeTransport.check(ml_session_generate_identity(&privateKey, &publicKey, &unused))
        defer { for index in privateKey.indices { privateKey[index] = 0 }; for index in unused.indices { unused[index] = 0 } }
        return Self(privateKey: Data(privateKey))
    }
    /// The name a sharing Mac lists this Mac by.
    static var computerName: String { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac" }
}

/// A pairing code validated by Rust. Its format, address rule, name rule and
/// peer ID are Rust's; Swift only moves it between the clipboard and Keychain.
struct NativePairingCode {
    /// How it proves this Mac to the sharing Mac.
    enum Kind: UInt8 {
        /// The sharing Mac's long-lived secret, from before per-device keys.
        case legacy = 1
        /// A code that approves one Mac, once, within ten minutes.
        case oneTime = 2
        /// Saved after approval: this Mac's own key, no shared secret.
        case device = 3
    }
    let raw: MLPairingCode
    var address: String { nativeString(raw.address) }
    /// The sharing Mac's other addresses, from a one-time code.
    var alternates: [String] { nativeString(raw.alternates).split(separator: " ").map(String.init) }
    /// Every address, the main one first.
    var addresses: [String] { [address] + alternates }
    var name: String { nativeString(raw.name) }
    /// Lowercase hex SHA-256 of the public key; contains no secret material.
    var peerID: String { nativeString(raw.peer_id) }
    var publicKey: Data { withUnsafeBytes(of: raw.public_key) { Data($0) } }
    var secret: Data { withUnsafeBytes(of: raw.secret) { Data($0) } }
    var kind: Kind? { Kind(rawValue: raw.kind) }

    /// This Mac's network addresses for its codes, best first (Rust's rule).
    static func localAddresses() -> [String] {
        var text = [CChar](repeating: 0, count: Int(ML_ALTERNATES_CAPACITY))
        guard ml_local_addresses(&text, text.count) == ML_SESSION_OK else { return [] }
        return nativeString(text).split(separator: " ").map(String.init)
    }
    /// A one-time code for this Mac, listing its other addresses too. Rust
    /// normalizes the computer name rather than failing, and leaves out
    /// addresses that don't qualify or fit.
    static func forHost(address: String, computerName: String, identity: NativeHostIdentity, oneTimeSecret: Data,
                        alternates: [String] = []) throws -> Self {
        try identity.validate()
        guard oneTimeSecret.count == 32 else { throw NativeSessionError(message: "The pairing code could not be made. Try again.") }
        var raw = MLPairingCode()
        let status = identity.publicKey.withUnsafeBytes { publicBytes in
            oneTimeSecret.withUnsafeBytes { secretBytes in
                ml_pairing_code_for_host(address, computerName, publicBytes.bindMemory(to: UInt8.self).baseAddress!,
                                         secretBytes.bindMemory(to: UInt8.self).baseAddress!, Kind.oneTime.rawValue,
                                         alternates.joined(separator: " "), &raw)
            }
        }
        guard status == ML_SESSION_OK else {
            throw NativeSessionError(message: "This Mac's local network name could not be used in a pairing code.")
        }
        return Self(raw: raw)
    }
    /// What to save once the sharing Mac approved this Mac's key.
    func device() throws -> Self {
        var raw = raw
        var device = MLPairingCode()
        try NativeTransport.check(ml_pairing_device(&raw, &device))
        return Self(raw: device)
    }
    static func parse(_ text: String) throws -> Self {
        var raw = MLPairingCode()
        guard ml_pairing_code_parse(text, &raw) == ML_SESSION_OK else {
            throw NativeSessionError(message: "Paste the pairing code from Share This Mac on your other Mac.")
        }
        return Self(raw: raw)
    }
    func encoded() throws -> String {
        var raw = raw
        var text = [CChar](repeating: 0, count: Int(ML_PAIRING_CODE_CAPACITY))
        try NativeTransport.check(ml_pairing_code_encode(&raw, &text, text.count))
        return nativeString(text)
    }
    /// The Keychain representation; readable from earlier pairings.
    func credential() throws -> Data {
        var raw = raw
        var bytes = [UInt8](repeating: 0, count: Int(ML_CREDENTIAL_CAPACITY))
        var length = 0
        try NativeTransport.check(ml_pairing_credential_encode(&raw, &bytes, bytes.count, &length))
        defer { for index in bytes.indices { bytes[index] = 0 } }
        return Data(bytes.prefix(length))
    }
    static func fromCredential(_ data: Data) throws -> Self {
        var raw = MLPairingCode()
        let status = data.withUnsafeBytes { bytes in
            ml_pairing_credential_decode(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &raw)
        }
        guard status == ML_SESSION_OK else {
            throw NativeSessionError(message: "The saved pairing credential could not be read. Pair the Macs again.")
        }
        return Self(raw: raw)
    }
    /// The shared host rule: normalized, or nil for URLs, ports and credentials.
    static func normalizedAddress(_ address: String) -> String? {
        var output = [CChar](repeating: 0, count: Int(ML_TEXT_CAPACITY))
        guard ml_address_normalize(address, &output, output.count) == ML_SESSION_OK else { return nil }
        return nativeString(output)
    }
}

/// A Mac approved to connect to this one.
struct NativeDevice: Equatable {
    let id: String
    let name: String
    let paired: Date
    let lastSeen: Date
    /// Moved over from the old pairing code rather than paired with a one-time code.
    let migrated: Bool
    init(_ raw: MLDevice) {
        id = nativeString(raw.id); name = nativeString(raw.name)
        paired = Date(timeIntervalSince1970: TimeInterval(raw.paired))
        lastSeen = Date(timeIntervalSince1970: TimeInterval(raw.last_seen))
        migrated = raw.via == UInt8(ML_DEVICE_VIA_MIGRATED)
    }
}

/// Whether Macs paired before per-device keys may still use the old code:
/// while accepted, and before closesAt.
struct NativeLegacyState: Equatable {
    /// Until stopped; it may still have passed its end.
    var accepted = false
    /// Nil until the first Mac moves over.
    var closesAt: Date?
    var lastUsed: Date?
    init() {}
    init(_ raw: MLLegacyState) {
        accepted = raw.accepted == 1
        closesAt = raw.closes_at == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(raw.closes_at))
        lastUsed = raw.last_used == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(raw.last_used))
    }
    /// Accepted and not past its end.
    var isOpen: Bool { accepted && (closesAt.map { $0 > Date() } ?? true) }
}

/// Macs approved to connect to this one, in Rust's store: public keys and
/// names only. A nil directory selects MOORING_HOME or Application Support.
struct NativeDeviceStore {
    var directory: String?

    /// Creates the list if it doesn't exist; an existing one is kept.
    func prepare(acceptOldCode: Bool) throws { try NativeTransport.check(ml_devices_init(directory, acceptOldCode ? 1 : 0)) }
    func load() throws -> (devices: [NativeDevice], legacy: NativeLegacyState) {
        var devices = [MLDevice](repeating: MLDevice(), count: Int(ML_DEVICES_MAX))
        var count = 0
        var legacy = MLLegacyState()
        try NativeTransport.check(ml_devices_load(directory, &devices, devices.count, &count, &legacy))
        return (devices.prefix(count).map(NativeDevice.init), NativeLegacyState(legacy))
    }
    func remove(_ id: String) throws { try NativeTransport.check(ml_devices_remove(directory, id)) }
    /// Stop accepting the old code now, or for another week from now.
    func stopOldCode() throws { try NativeTransport.check(ml_devices_legacy_action(directory, UInt8(ML_LEGACY_STOP_NOW))) }
    func extendOldCode() throws { try NativeTransport.check(ml_devices_legacy_action(directory, UInt8(ML_LEGACY_ANOTHER_WEEK))) }
    /// No Mac approved, and the old code never accepted again.
    func reset() throws { try NativeTransport.check(ml_devices_reset(directory)) }
}

struct NativePeer: Equatable {
    let id: String
    let name: String
    let address: String
    /// Tried with `address`, which is the one that last worked.
    let alternates: [String]
    var addresses: [String] { [address] + alternates }
    init(_ raw: MLPeer) {
        id = nativeString(raw.id); name = nativeString(raw.name); address = nativeString(raw.address)
        alternates = nativeString(raw.alternates).split(separator: " ").map(String.init)
    }
    init(code: NativePairingCode, address: String) {
        id = code.peerID; name = code.name; self.address = address
        alternates = code.addresses.filter { $0 != address }
    }
}

/// Saved peer metadata lives in Rust's store: never secrets, at most 32 peers.
/// A nil directory selects MOORING_HOME or Application Support.
struct NativePeerStore {
    var directory: String?

    func load() throws -> [NativePeer] {
        var peers = [MLPeer](repeating: MLPeer(), count: Int(ML_PEERS_MAX))
        var count = 0
        try NativeTransport.check(ml_peers_load(directory, &peers, peers.count, &count))
        return peers.prefix(count).map(NativePeer.init)
    }
    @discardableResult
    /// `tried`: the addresses the connection used, the one that connected first.
    func remember(_ code: NativePairingCode, tried: [String]) throws -> NativePeer {
        var raw = code.raw
        var peer = MLPeer()
        try NativeTransport.check(ml_peers_remember(directory, &raw, tried.joined(separator: " "), &peer))
        return NativePeer(peer)
    }
    /// After a saved Mac connected through `address`: it's tried first next time.
    func connected(_ id: String, through address: String) throws {
        try NativeTransport.check(ml_peers_connected(directory, id, address))
    }
    func forget(_ id: String) throws { try NativeTransport.check(ml_peers_forget(directory, id)) }
    /// One-time import of the earlier preference list; a no-op once a store exists.
    func importLegacy(_ data: Data) throws {
        let status = data.withUnsafeBytes { bytes in
            ml_peers_import_legacy(directory, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, nil)
        }
        try NativeTransport.check(status)
    }
}

/// Secrets never enter preferences, diagnostic files, CLI arguments or logs.
struct NativeKeychain {
    private let service = (Bundle.main.bundleIdentifier ?? "dev.maclink.launcher") + ".native-pairing.v1"

    func hostIdentity() throws -> NativeHostIdentity? {
        guard let data = try read("host") else { return nil }
        guard let identity = try? JSONDecoder().decode(NativeHostIdentity.self, from: data) else {
            throw NativeSessionError(message: "The saved pairing identity could not be read. Reset pairing on this Mac.")
        }
        return identity
    }
    func saveHostIdentity(_ identity: NativeHostIdentity) throws { try save("host", data: JSONEncoder().encode(identity)) }
    /// This Mac's device key, made on first use.
    func deviceKey() throws -> NativeDeviceKey {
        if let data = try read("device") {
            guard data.count == 32 else {
                throw NativeSessionError(message: "This Mac's saved device key could not be read. Pair the Macs again.")
            }
            return NativeDeviceKey(privateKey: data)
        }
        let key = try NativeDeviceKey.create()
        try save("device", data: key.privateKey)
        return key
    }
    func peerCode(_ peerID: String) throws -> NativePairingCode? {
        try read("peer-" + peerID).map(NativePairingCode.fromCredential)
    }
    func savePeerCode(_ code: NativePairingCode) throws { try save("peer-" + code.peerID, data: code.credential()) }
    func deletePeerCode(_ peerID: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: "peer-" + peerID]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw failure(status) }
        return data
    }
    private func save(_ account: String, data: Data) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        let updates: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrLabel as String: "Mooring paired connection",
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            updates.forEach { insert[$0.key] = $0.value }
            insert[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> NativeSessionError {
        NativeSessionError(message: "Keychain could not access the pairing credential (\(status)). Unlock this Mac and try again.")
    }
}
