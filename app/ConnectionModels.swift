import Foundation

struct SavedMac: Decodable {
    struct SSHHop: Decodable { let target: String }
    let id: String
    let name: String
    /// With `ssh`, the VNC address as seen from the SSH host.
    let host: String
    let port: UInt16
    /// "vnc" for a VNC server such as wayvnc on Linux. "mac", or no value in
    /// older saves, marks an address saved for Apple Screen Sharing, which
    /// Mooring no longer opens; it is kept so the person can pair or remove it.
    let server: String?
    let ssh: SSHHop?

    var isMac: Bool { (server ?? "mac") == "mac" }
    /// Mooring's own viewer opens VNC servers that are not Macs, through SSH.
    var opensInMooring: Bool { !isMac && ssh != nil }

    var endpoint: String {
        let address = host.contains(":") ? "[\(host)]" : host
        let direct = port == 5900 ? host : "\(address):\(port)"
        guard let ssh else { return direct }
        return host == "127.0.0.1" && port == 5900 ? "via SSH \(ssh.target)" : "\(direct) via SSH \(ssh.target)"
    }
}

struct HostInspection: Decodable {
    let host: String
    let port: UInt16
    let tcp_connect_ms: Double?
    let rfb_version: String?
    let note: String?
    /// SSH connections to other VNC servers: whether the desktop is locked.
    let desktop: DesktopReport?
    let desktop_error: DesktopError?
}

/// Rust decides the wording; the app only shows it.
struct DesktopReport: Decodable {
    let lock: String
    let title: String
    let message: String
    let notes: [String]?
}

struct DesktopError: Decodable {
    let message: String
}
