import Foundation

/// Pairing/trust application service. These operations preserve the ordering
/// between public metadata and credentials; they have no UI or session effects.
final class NativeTrustWorkflow {
    private let keychain: any NativeCredentialVault
    private let peerStore: any NativePeerRepository
    private let deviceStore: any NativeDeviceRepository
    init(credentials: any NativeCredentialVault, peers: any NativePeerRepository, devices: any NativeDeviceRepository) {
        keychain = credentials; peerStore = peers; deviceStore = devices
    }
    func prepareHostIdentity() throws -> NativeHostIdentity {
        var identity: NativeHostIdentity
        if let saved = try keychain.hostIdentity() { try saved.validate(); identity = saved }
        else {
            // A new identity approves no Mac: clear any list left from an earlier one first.
            try deviceStore.reset()
            identity = try NativeHostIdentity.create(); try keychain.saveHostIdentity(identity)
        }
        // A Mac that shared before per-device keys keeps accepting its old
        // code, so its paired Macs can move over; a new identity never does.
        try deviceStore.prepare(acceptOldCode: identity.listsDevices != true)
        if identity.listsDevices != true {
            var marked = identity; marked.listsDevices = true
            do { try keychain.saveHostIdentity(marked); identity = marked }
            catch { NativeLog.session.error("couldn't note the approved-Mac list with this Mac's identity") }
        }
        return identity
    }
    func forget(peerID: String) throws {
        // If credential erasure fails, preserve the visible row for retry.
        try keychain.deletePeerCode(peerID)
        try peerStore.forget(peerID)
    }
}
