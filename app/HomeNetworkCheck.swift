import Foundation

struct AutomationSettings: Codable {
    var enabled = true
    var paused = false
    var targetID = ""
    var homeRoute = ""
    var additionalHomeRoutes: [String] = []
    var allowVPN = false
    var highPerformanceConfirmed = false
    var fullScreen = true
    var autoConnect = true
    var preference = "auto"
    var automaticHighPerformanceTrial = true
    var familiarPaths: [String] = []
    var permissionPromptShown = false

    /// An explicit connection selects the managed Mac; browsing the list does not.
    mutating func selectForConnection(_ id: String) {
        guard enabled else { return }
        targetID = id
        paused = false
    }

    static func familiarKey(targetID: String, fingerprint: String) -> String {
        targetID + "|" + fingerprint
    }

    mutating func rememberFamiliarPath(targetID: String, fingerprint: String) {
        guard !targetID.isEmpty, !fingerprint.isEmpty else { return }
        let key = Self.familiarKey(targetID: targetID, fingerprint: fingerprint)
        familiarPaths = Self.normalizedFamiliarPaths([key] + familiarPaths)
    }

    private static func normalizedFamiliarPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return Array(paths.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(8))
    }

    func recognizesPath(targetID: String, fingerprint: String?) -> Bool {
        guard let fingerprint, !fingerprint.isEmpty else { return false }
        return familiarPaths.contains(Self.familiarKey(targetID: targetID, fingerprint: fingerprint))
    }

    var homeRoutes: [String] {
        var seen = Set<String>()
        return Array(([homeRoute] + additionalHomeRoutes)
            .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(8))
    }

    mutating func rememberHome(_ fingerprint: String) {
        guard !fingerprint.isEmpty else { return }
        let previous = homeRoutes.filter { $0 != fingerprint }
        homeRoute = fingerprint
        additionalHomeRoutes = Array(previous.prefix(7))
    }

    mutating func forgetHomes() {
        homeRoute = ""
        additionalHomeRoutes = []
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, paused, targetID, homeRoute, additionalHomeRoutes, allowVPN
        case highPerformanceConfirmed, fullScreen, autoConnect, preference
        case automaticHighPerformanceTrial, familiarPaths, permissionPromptShown
    }
}

extension AutomationSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? paused
        targetID = try values.decodeIfPresent(String.self, forKey: .targetID) ?? targetID
        homeRoute = try values.decodeIfPresent(String.self, forKey: .homeRoute) ?? homeRoute
        additionalHomeRoutes = try values.decodeIfPresent([String].self, forKey: .additionalHomeRoutes) ?? []
        allowVPN = try values.decodeIfPresent(Bool.self, forKey: .allowVPN) ?? allowVPN
        highPerformanceConfirmed = try values.decodeIfPresent(Bool.self, forKey: .highPerformanceConfirmed) ?? highPerformanceConfirmed
        fullScreen = try values.decodeIfPresent(Bool.self, forKey: .fullScreen) ?? fullScreen
        autoConnect = try values.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? autoConnect
        preference = try values.decodeIfPresent(String.self, forKey: .preference) ?? preference
        // Old unconfigured installs adopt the new connection defaults. A configured
        // user's disabled automation, mode and display choices remain unchanged.
        if targetID.isEmpty && !values.contains(.automaticHighPerformanceTrial) { enabled = true }
        automaticHighPerformanceTrial = try values.decodeIfPresent(Bool.self, forKey: .automaticHighPerformanceTrial)
            ?? (targetID.isEmpty || !values.contains(.highPerformanceConfirmed))
        familiarPaths = Self.normalizedFamiliarPaths(try values.decodeIfPresent([String].self, forKey: .familiarPaths) ?? [])
        permissionPromptShown = try values.decodeIfPresent(Bool.self, forKey: .permissionPromptShown) ?? false
        additionalHomeRoutes = Array(homeRoutes.filter { $0 != homeRoute }.prefix(homeRoute.isEmpty ? 8 : 7))
    }
}

/// A settings check is independent of remote-session probes. Only the current
/// request can publish a candidate; invalidation or timeout rejects late replies.
struct HomeNetworkCheck {
    private(set) var requestID: UUID?
    private(set) var fingerprint: String?
    private(set) var description = "Detect the Wi-Fi or Ethernet network this Mac is using."
    var isChecking: Bool { requestID != nil }

    @discardableResult
    mutating func begin(request: UUID = UUID()) -> UUID {
        requestID = request
        fingerprint = nil
        description = "Detecting this Mac’s network…"
        return request
    }

    @discardableResult
    mutating func complete(request: UUID, description: String, fingerprint: String?) -> Bool {
        guard requestID == request else { return false }
        requestID = nil
        self.description = description
        self.fingerprint = fingerprint.flatMap { $0.isEmpty ? nil : $0 }
        return true
    }

    mutating func invalidate(reason: String) {
        requestID = nil
        fingerprint = nil
        description = reason
    }

    @discardableResult
    mutating func timeout(request: UUID) -> Bool {
        complete(request: request, description: "Network detection took too long. Check your Wi-Fi or Ethernet connection, then try again.", fingerprint: nil)
    }
}
