import Foundation

/// Wire DTOs are decoded once at the process/FFI edge. UI and application
/// workflows never inspect JSON dictionaries or guess required fields.
struct ConnectionFailure: Decodable {
    let kind: String?
    let message: String
}

struct TunnelReady: Decodable {
    struct Check: Decodable {
        let remoteHost: String
        let securityTypes: [UInt8]
    }
    let localPort: UInt16
    let check: Check
}

struct RemoteDesktop: Decodable {
    let sessionUser: String?
    let title: String
    let message: String
    let lock: String
}

struct RemoteScreen: Decodable {
    let state: String
    let kind: String?
    let width: Int?
    let height: Int?
    let previous: String?
    let error: ConnectionFailure?
}

enum TunnelEvent: Decodable {
    case ready(TunnelReady)
    case desktop(RemoteDesktop)
    case screen(RemoteScreen)
    case retry(ConnectionFailure?)
    case failed(ConnectionFailure?)
    case closed(String?)
    case ignored

    private enum Keys: String, CodingKey { case event, error, reason }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Keys.self)
        switch try fields.decode(String.self, forKey: .event) {
        case "ready":
            let ready = try TunnelReady(from: decoder)
            guard ready.localPort != 0 else {
                throw DecodingError.dataCorruptedError(forKey: .event, in: fields, debugDescription: "Invalid tunnel port")
            }
            self = .ready(ready)
        case "desktop": self = .desktop(try RemoteDesktop(from: decoder))
        case "virtual_screen": self = .screen(try RemoteScreen(from: decoder))
        case "check_retry": self = .retry(try fields.decodeIfPresent(ConnectionFailure.self, forKey: .error))
        case "failed": self = .failed(try fields.decodeIfPresent(ConnectionFailure.self, forKey: .error))
        case "closed": self = .closed(try fields.decodeIfPresent(String.self, forKey: .reason))
        default: self = .ignored
        }
    }

    static func decode(_ data: Data) throws -> TunnelEvent {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: data)
    }
}

enum VNCSessionEvent: Decodable {
    case picture(width: Int, height: Int, security: String?)
    case bell
    case closed(ConnectionFailure?)
    case ignored
    private enum Keys: String, CodingKey { case event, width, height, security, error }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Keys.self)
        switch try fields.decode(String.self, forKey: .event) {
        case "connected", "resized":
            let width = try fields.decode(UInt16.self, forKey: .width)
            let height = try fields.decode(UInt16.self, forKey: .height)
            guard width > 0, height > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .width, in: fields, debugDescription: "Invalid picture size")
            }
            self = .picture(width: Int(width), height: Int(height), security: try fields.decodeIfPresent(String.self, forKey: .security))
        case "bell": self = .bell
        case "closed": self = .closed(try fields.decodeIfPresent(ConnectionFailure.self, forKey: .error))
        default: self = .ignored
        }
    }
}

/// Application scheduling port; the production adapter uses the main queue.
protocol ConnectionScheduling {
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void)
}

struct MainConnectionScheduler: ConnectionScheduling {
    func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

protocol TunnelRunning: AnyObject {
    var onEvent: ((SavedMac, TunnelEvent) -> Void)? { get set }
    var onExit: ((SavedMac, Int32, String) -> Void)? { get set }
    func isRunning(_ id: String) -> Bool
    func open(_ mac: SavedMac, executable: URL, extraArguments: [String]) throws
    func stop(_ id: String)
    func stopAll(wait: TimeInterval)
}

enum LinuxConnectionPhase: UInt32 {
    case connecting = 0, waitingForDesktop, authenticating, viewing, ended, closed
}
enum LinuxConnectionTransition: UInt32 {
    case tunnelReady = 1, desktopReadyOrTimedOut, viewerStarted, retryRequested, close, viewerEnded
}
enum LinuxConnectionEffect: Int32 {
    case invalid = -1, none = 0, waitForDesktop, askForSignIn, stopTunnel
}

/// A flow is scoped to one attempt, not just a saved connection ID.
final class LinuxConnectionAttempt {
    private var state: MLLinuxFlow
    var phase: LinuxConnectionPhase { LinuxConnectionPhase(rawValue: state.phase) ?? .closed }
    var port: UInt16 { state.port }
    var route: TunnelReady.Check?
    var desktop: RemoteDesktop?
    var pixelsPerPoint: Double?
    var terminalEventReceived = false
    init(generation: UInt64) {
        state = MLLinuxFlow(generation: generation, phase: 0, port: 0, reserved: 0)
    }
    @discardableResult
    func apply(_ event: LinuxConnectionTransition, generation: UInt64? = nil, port: UInt16 = 0) -> LinuxConnectionEffect {
        LinuxConnectionEffect(rawValue: ml_linux_flow_step(&state, generation ?? state.generation, event.rawValue, port)) ?? .invalid
    }
}
