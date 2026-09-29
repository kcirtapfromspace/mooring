import Foundation
import Security

struct NativeSessionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The sharing Mac's Noise identity and pairing secret, stored only in Keychain.
struct NativeHostIdentity: Codable {
    let privateKey: Data
    let publicKey: Data
    let secret: Data

    static func create() throws -> Self {
        var privateKey = [UInt8](repeating: 0, count: 32)
        var publicKey = [UInt8](repeating: 0, count: 32)
        var secret = [UInt8](repeating: 0, count: 32)
        try NativeTransport.check(ml_session_generate_identity(&privateKey, &publicKey, &secret))
        return Self(privateKey: Data(privateKey), publicKey: Data(publicKey), secret: Data(secret))
    }
    func validate() throws {
        guard privateKey.count == 32, publicKey.count == 32, secret.count == 32 else {
            throw NativeSessionError(message: "The saved pairing identity is invalid. Reset pairing on this Mac.")
        }
    }
}

/// A pairing code validated by Rust. Its format, address rule, name rule and
/// peer ID are Rust's; Swift only moves it between the clipboard and Keychain.
struct NativePairingCode {
    let raw: MLPairingCode
    var address: String { nativeString(raw.address) }
    var name: String { nativeString(raw.name) }
    /// Lowercase hex SHA-256 of the public key; contains no secret material.
    var peerID: String { nativeString(raw.peer_id) }
    var publicKey: Data { withUnsafeBytes(of: raw.public_key) { Data($0) } }
    var secret: Data { withUnsafeBytes(of: raw.secret) { Data($0) } }

    /// This Mac's code. Rust normalizes the computer name rather than failing.
    static func forHost(address: String, computerName: String, identity: NativeHostIdentity) throws -> Self {
        try identity.validate()
        var raw = MLPairingCode()
        let status = identity.publicKey.withUnsafeBytes { publicBytes in
            identity.secret.withUnsafeBytes { secretBytes in
                ml_pairing_code_for_host(address, computerName, publicBytes.bindMemory(to: UInt8.self).baseAddress!,
                                         secretBytes.bindMemory(to: UInt8.self).baseAddress!, &raw)
            }
        }
        guard status == ML_SESSION_OK else {
            throw NativeSessionError(message: "This Mac's local network name could not be used in a pairing code.")
        }
        return Self(raw: raw)
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

struct NativePeer: Equatable {
    let id: String
    let name: String
    let address: String
    init(_ raw: MLPeer) { id = nativeString(raw.id); name = nativeString(raw.name); address = nativeString(raw.address) }
    init(code: NativePairingCode, address: String) { id = code.peerID; name = code.name; self.address = address }
}

/// Saved peer metadata lives in Rust's store: never secrets, at most 32 peers.
/// A nil directory selects MACLINK_HOME or Application Support.
struct NativePeerStore {
    var directory: String?

    func load() throws -> [NativePeer] {
        var peers = [MLPeer](repeating: MLPeer(), count: Int(ML_PEERS_MAX))
        var count = 0
        try NativeTransport.check(ml_peers_load(directory, &peers, peers.count, &count))
        return peers.prefix(count).map(NativePeer.init)
    }
    @discardableResult
    func remember(_ code: NativePairingCode, address: String) throws -> NativePeer {
        var raw = code.raw
        var peer = MLPeer()
        try NativeTransport.check(ml_peers_remember(directory, &raw, address, &peer))
        return NativePeer(peer)
    }
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
    func peerCode(_ peerID: String) throws -> NativePairingCode? {
        try read("peer-" + peerID).map(NativePairingCode.fromCredential)
    }
    func savePeerCode(_ code: NativePairingCode) throws { try save("peer-" + code.peerID, data: code.credential()) }

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
                                     kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            updates.forEach { insert[$0.key] = $0.value }
            insert[kSecAttrSynchronizable as String] = false
            insert[kSecAttrLabel as String] = "MacLink paired connection"
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> NativeSessionError {
        NativeSessionError(message: "Keychain could not access the pairing credential (\(status)). Unlock this Mac and try again.")
    }
}
