import Foundation

@main
struct HomeNetworkTests {
    static func main() throws {
        var check = HomeNetworkCheck()
        let first = check.begin()
        let second = check.begin()
        precondition(!check.complete(request: first, description: "stale", fingerprint: "wrong"))
        precondition(check.requestID == second && check.fingerprint == nil)
        precondition(check.complete(request: second, description: "Home Wi-Fi", fingerprint: "wifi"))
        precondition(!check.isChecking && check.fingerprint == "wifi")
        precondition(!check.timeout(request: second) && check.fingerprint == "wifi")

        let timedOut = check.begin()
        precondition(check.timeout(request: timedOut))
        precondition(!check.isChecking && check.fingerprint == nil)
        precondition(!check.complete(request: timedOut, description: "late", fingerprint: "stale"))
        let invalidated = check.begin()
        check.invalidate(reason: "Network changed. Detect it again.")
        precondition(!check.complete(request: invalidated, description: "late", fingerprint: "old-network"))
        precondition(!check.isChecking && check.fingerprint == nil)
        let failed = check.begin()
        precondition(check.complete(request: failed, description: "No network available", fingerprint: nil))
        precondition(!check.isChecking && check.fingerprint == nil)

        // Detecting is independent of any target and never marks a home by itself.
        var settings = AutomationSettings()
        let ready = check.begin()
        precondition(check.complete(request: ready, description: "Local network", fingerprint: "wifi"))
        precondition(settings.targetID.isEmpty && settings.homeRoutes.isEmpty)
        settings.rememberHome(check.fingerprint!)
        settings.rememberHome("ethernet")
        settings.rememberHome("wifi")
        precondition(settings.homeRoutes == ["wifi", "ethernet"])
        let saved = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(settings))
        precondition(saved.homeRoutes == ["wifi", "ethernet"] && saved.targetID.isEmpty)
        for index in 0..<20 { settings.rememberHome("network-\(index)") }
        precondition(settings.homeRoutes.count == 8 && settings.homeRoutes.first == "network-19")
        settings.forgetHomes()
        precondition(settings.homeRoutes.isEmpty)

        let old = Data(#"{"enabled":true,"paused":true,"targetID":"mac-1","homeRoute":"old-home","allowVPN":true,"highPerformanceConfirmed":true,"fullScreen":false,"autoConnect":false,"preference":"standard"}"#.utf8)
        let migrated = try JSONDecoder().decode(AutomationSettings.self, from: old)
        precondition(migrated.enabled && migrated.paused && migrated.allowVPN && migrated.highPerformanceConfirmed)
        precondition(migrated.targetID == "mac-1" && migrated.homeRoutes == ["old-home"])
        precondition(migrated.additionalHomeRoutes.isEmpty && !migrated.fullScreen && !migrated.autoConnect)
        precondition(migrated.preference == "standard")
        print("Home-network state tests passed: stale replies, timeout, invalidation, failure recovery, independent detection, mark/save, deduplication, bounds, migration.")
    }
}
