import Foundation

/// Experimental reachability adapter. Only public, expiring locators live in
/// memory. Existing paired identities still authorize every native session.
final class NativeInternetLinks {
    static let shared = NativeInternetLinks()
    static var isAvailable: Bool { ml_internet_available() == 1 }
    private let lock = NSLock()
    private var routes: [String: String] = [:]
    private let identity: () throws -> Data
    init(identity: @escaping () throws -> Data = { try NativeKeychain().internetIdentity() }) { self.identity = identity }
    func withIdentity<T>(_ body: (UnsafePointer<UInt8>) throws -> T) throws -> T {
        let saved: Data = try {
            lock.lock(); defer { lock.unlock() }
            return try identity()
        }()
        var bytes = [UInt8](saved)
        defer { for index in bytes.indices { bytes[index] = 0 } }
        guard bytes.count == 32 else { throw NativeSessionError(message: "Invalid internet transport identity.") }
        return try bytes.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }
    func publicID() throws -> String {
        var text = [CChar](repeating: 0, count: 65)
        let status = try withIdentity { ml_internet_public_id($0, &text, text.count) }
        try NativeTransport.check(status)
        return nativeString(text)
    }
    func start(listener: NativeTransport, allowed: String, relay: String) throws -> String {
        var ticket = [CChar](repeating: 0, count: 8193)
        let status = try withIdentity { ml_internet_listen(listener.listenerID, $0, allowed, relay, 0, &ticket, ticket.count) }
        try NativeTransport.check(status)
        return nativeString(ticket)
    }
    func setRoute(_ ticket: String, for peerID: String) throws {
        guard Self.isAvailable, ticket.utf8.count <= 8192, !ticket.isEmpty else {
            throw NativeSessionError(message: "Paste an internet locator from an experimental Mooring build.")
        }
        lock.lock(); defer { lock.unlock() }
        guard routes[peerID] != nil || routes.count < 32 else { throw NativeSessionError(message: "Too many temporary internet routes.") }
        routes[peerID] = ticket
    }
    func route(for peerID: String) -> String? {
        guard Self.isAvailable else { return nil }
        lock.lock(); defer { lock.unlock() }
        return routes[peerID]
    }
    func removeRoute(for peerID: String) { lock.lock(); routes[peerID] = nil; lock.unlock() }
}
