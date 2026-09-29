import Foundation

@main
struct HomeNetworkTests {
    static func main() throws {
        let defaults = AutomationSettings()
        precondition(defaults.enabled && !defaults.paused && defaults.targetID.isEmpty)
        precondition(defaults.autoConnect && defaults.fullScreen && defaults.preference == "auto")
        precondition(defaults.automaticHighPerformanceTrial && !defaults.highPerformanceConfirmed && !defaults.allowVPN)
        precondition(defaults.familiarPaths.isEmpty && defaults.homeRoutes.isEmpty && !defaults.permissionPromptShown)

        // Explicit connection intent selects a target and resumes it; selection
        // cannot infer familiarity, confirm capability, or undo automation off.
        var selected = defaults
        selected.paused = true
        selected.selectForConnection("mac-a")
        precondition(selected.targetID == "mac-a" && !selected.paused)
        precondition(selected.familiarPaths.isEmpty && selected.homeRoutes.isEmpty && !selected.highPerformanceConfirmed)
        selected.selectForConnection("mac-b")
        precondition(selected.targetID == "mac-b")
        selected.enabled = false
        selected.paused = true
        selected.selectForConnection("mac-c")
        precondition(selected.targetID == "mac-b" && !selected.enabled && selected.paused)

        // Familiarity belongs to one explicitly connected Mac on one path. A
        // second target, nil fingerprint, or different network gets no match.
        var familiar = defaults
        familiar.rememberFamiliarPath(targetID: "mac-a", fingerprint: "wifi")
        familiar.rememberFamiliarPath(targetID: "mac-a", fingerprint: "ethernet")
        familiar.rememberFamiliarPath(targetID: "mac-a", fingerprint: "wifi")
        precondition(familiar.familiarPaths == ["mac-a|wifi", "mac-a|ethernet"])
        precondition(familiar.recognizesPath(targetID: "mac-a", fingerprint: "wifi"))
        precondition(!familiar.recognizesPath(targetID: "mac-b", fingerprint: "wifi"))
        precondition(!familiar.recognizesPath(targetID: "mac-a", fingerprint: "travel"))
        precondition(!familiar.recognizesPath(targetID: "mac-a", fingerprint: nil))
        precondition(!familiar.recognizesPath(targetID: "mac-a", fingerprint: ""))
        familiar.rememberFamiliarPath(targetID: "", fingerprint: "wifi")
        familiar.rememberFamiliarPath(targetID: "mac-a", fingerprint: "")
        precondition(familiar.familiarPaths.count == 2)
        for index in 0..<20 { familiar.rememberFamiliarPath(targetID: "mac-a", fingerprint: "path-\(index)") }
        precondition(familiar.familiarPaths == (12..<20).reversed().map { "mac-a|path-\($0)" })
        precondition(!familiar.recognizesPath(targetID: "mac-a", fingerprint: "wifi"))
        familiar.rememberFamiliarPath(targetID: "mac-b", fingerprint: "path-19")
        precondition(familiar.familiarPaths.count == 8 && familiar.familiarPaths.first == "mac-b|path-19")
        precondition(familiar.recognizesPath(targetID: "mac-a", fingerprint: "path-19"))
        precondition(familiar.recognizesPath(targetID: "mac-b", fingerprint: "path-19"))
        let familiarSaved = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(familiar))
        precondition(familiarSaved.familiarPaths == familiar.familiarPaths)
        let duplicated = Data(#"{"familiarPaths":["mac-a|wifi","","mac-a|wifi","mac-b|wifi","mac-a|ethernet","a","b","c","d","e","f"]}"#.utf8)
        let cleaned = try JSONDecoder().decode(AutomationSettings.self, from: duplicated)
        precondition(cleaned.familiarPaths == ["mac-a|wifi", "mac-b|wifi", "mac-a|ethernet", "a", "b", "c", "d", "e"])

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
        precondition(migrated.preference == "standard" && !migrated.automaticHighPerformanceTrial)

        let disabledOld = Data(#"{"enabled":false,"paused":true,"targetID":"mac-1","highPerformanceConfirmed":false,"fullScreen":false,"autoConnect":false,"preference":"standard"}"#.utf8)
        var disabledMigrated = try JSONDecoder().decode(AutomationSettings.self, from: disabledOld)
        precondition(!disabledMigrated.enabled && disabledMigrated.paused && !disabledMigrated.automaticHighPerformanceTrial)
        precondition(!disabledMigrated.fullScreen && !disabledMigrated.autoConnect && disabledMigrated.preference == "standard")
        disabledMigrated.selectForConnection("mac-2")
        precondition(disabledMigrated.targetID == "mac-1" && !disabledMigrated.enabled)

        let unconfiguredOld = Data(#"{"enabled":false,"targetID":"","highPerformanceConfirmed":false,"homeRoute":"saved-home"}"#.utf8)
        let adopted = try JSONDecoder().decode(AutomationSettings.self, from: unconfiguredOld)
        precondition(adopted.enabled && adopted.automaticHighPerformanceTrial && adopted.autoConnect && adopted.fullScreen)
        precondition(adopted.targetID.isEmpty && adopted.homeRoutes == ["saved-home"] && !adopted.highPerformanceConfirmed)

        // New-schema choices survive relaunch even before a Mac is selected.
        var explicitDisabled = defaults
        explicitDisabled.enabled = false
        explicitDisabled.automaticHighPerformanceTrial = false
        explicitDisabled.fullScreen = false
        explicitDisabled.permissionPromptShown = true
        let restoredDisabled = try JSONDecoder().decode(AutomationSettings.self, from: JSONEncoder().encode(explicitDisabled))
        precondition(restoredDisabled.targetID.isEmpty && !restoredDisabled.enabled && !restoredDisabled.automaticHighPerformanceTrial)
        precondition(!restoredDisabled.fullScreen && restoredDisabled.permissionPromptShown)
        print("Home-network and defaults tests passed: defaults, explicit target selection, disabled preservation, target-isolated familiarity, deduplication, bounds, migration, stale replies, timeout, invalidation, failure recovery, independent detection, mark/save.")
    }
}
