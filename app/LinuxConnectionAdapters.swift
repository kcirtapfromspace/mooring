import AppKit

typealias LinuxSignInAnswer = (username: String, password: [UInt8])
typealias LinuxSignInPrompt = (String, String?, String, @escaping (LinuxSignInAnswer?) -> Void) -> Void

protocol LinuxVNCConnecting {
    func signInNeeds(_ route: TunnelReady.Check) -> (Int32, Int32)
    func signInAllowance(_ id: String) -> (Int32, UInt64, UInt32)
    func open(_ id: String, port: UInt16, remoteHost: String, username: String, password: [UInt8]) -> (Int32, UInt64)
    func close(_ session: UInt64)
}

struct RustLinuxVNCClient: LinuxVNCConnecting {
    func signInNeeds(_ route: TunnelReady.Check) -> (Int32, Int32) {
        var needs: Int32 = -1
        let status = route.remoteHost.withCString { host in
            route.securityTypes.withUnsafeBufferPointer { ml_vnc_sign_in_needs(host, $0.baseAddress, $0.count, &needs) }
        }
        return (status, needs)
    }
    func signInAllowance(_ id: String) -> (Int32, UInt64, UInt32) {
        var wait: UInt64 = 0, remaining: UInt32 = 0
        let status = id.withCString { ml_vnc_sign_in_check($0, &wait, &remaining) }
        return (status, wait, remaining)
    }
    func open(_ id: String, port: UInt16, remoteHost: String, username: String, password: [UInt8]) -> (Int32, UInt64) {
        var password = password
        defer { for index in password.indices { password[index] = 0 } }
        var session: UInt64 = 0
        let status = id.withCString { key in
            remoteHost.withCString { host in
                username.withCString { user in
                    password.withUnsafeMutableBufferPointer { ml_vnc_open(key, port, host, user, $0.baseAddress, $0.count, &session) }
                }
            }
        }
        return (status, session)
    }
    func close(_ session: UInt64) { if session != 0 { _ = ml_vnc_close(session) } }
}

protocol LinuxViewerPresenting: AnyObject {
    var sessionID: UInt64 { get }
    var isClosed: Bool { get }
    var remotePixelsPerPoint: CGFloat? { get set }
    var extendsBesideCamera: Bool { get set }
    var onClose: (() -> Void)? { get set }
    var onDiagnosticBarChange: ((Bool) -> Void)? { get set }
    var onAllowSystemKeys: (() -> Void)? { get set }
    var onSignInRejected: ((String) -> Void)? { get set }
    var onEnded: ((String?) -> Void)? { get set }
    var onReconnect: (() -> Void)? { get set }
    func showDesktop(_ title: String)
    func showWindow(_ sender: Any?)
    func close()
    func end(_ message: String?)
}

extension VNCViewerWindow: LinuxViewerPresenting {
    var sessionID: UInt64 { view.sessionID }
}
