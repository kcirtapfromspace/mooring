import Foundation

protocol NativeCredentialVault {
    func hostIdentity() throws -> NativeHostIdentity?
    func saveHostIdentity(_ identity: NativeHostIdentity) throws
    func peerCode(_ peerID: String) throws -> NativePairingCode?
    func peerDeviceKey(_ peerID: String) throws -> NativeDeviceKey
    func savePeerCode(_ code: NativePairingCode, deviceKey: NativeDeviceKey?) throws
    func deletePeerCode(_ peerID: String) throws
}
extension NativeKeychain: NativeCredentialVault {}

protocol NativePeerRepository {
    func load() throws -> [NativePeer]
    func remember(_ code: NativePairingCode, tried: [String]) throws -> NativePeer
    func connected(_ id: String, through address: String) throws
    func forget(_ id: String) throws
    func importLegacy(_ data: Data) throws
}
extension NativePeerStore: NativePeerRepository {}

protocol NativeDeviceRepository {
    var directory: String? { get }
    func prepare(acceptOldCode: Bool) throws
    func load() throws -> (devices: [NativeDevice], legacy: NativeLegacyState)
    func remove(_ id: String) throws
    func stopOldCode() throws
    func extendOldCode() throws
    func reset() throws
}
extension NativeDeviceStore: NativeDeviceRepository {}

/// One composition point for blocking session operations. Tests can replace
/// these effects without opening listeners, contacting a peer or using Keychain.
struct NativeSessionIO {
    var listen: (NativeHostIdentity, any NativeDeviceRepository) throws -> NativeTransport = {
        try NativeTransport.listen(identity: $0, devices: $1)
    }
    var listenForPIN: (NativeHostIdentity, any NativeDeviceRepository) throws -> NativeTransport = {
        try NativeTransport.listenForPIN(identity: $0, devices: $1)
    }
    var connect: ([String], NativePairingCode, NativeDeviceKey) throws -> (NativeTransport, NativeTransport.Mode, String) = {
        try NativeTransport.connect(addresses: $0, code: $1, deviceKey: $2)
    }
    var pairWithPIN: (String, [String], NativeDeviceKey) throws -> (NativePairingCode, String) = {
        try NativeTransport.pairWithPIN($0, addresses: $1, deviceKey: $2)
    }
}

struct NativeSessionDependencies {
    var defaults: UserDefaults = ProcessInfo.processInfo.environment["MOORING_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
    var credentials: any NativeCredentialVault = NativeKeychain()
    var peers: any NativePeerRepository = NativePeerStore()
    var devices: any NativeDeviceRepository = NativeDeviceStore()
    var io = NativeSessionIO()
    var scheduler: any ConnectionScheduling = MainConnectionScheduler()
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
}
