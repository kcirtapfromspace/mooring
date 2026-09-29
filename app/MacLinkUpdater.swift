import AppKit
import Sparkle

/// Keeps MacLink current from the public release feed. Sparkle checks every
/// four hours, downloads in the background and verifies the signed feed, the
/// update's EdDSA signature and that it carries the same Developer ID. MacLink
/// then installs and relaunches only while idle, so no session is interrupted.
final class MacLinkUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// True when relaunching now would not interrupt anything.
    var isIdle: () -> Bool = { true }
    var onChange: (() -> Void)?
    /// The version downloaded, verified and waiting for an idle moment.
    private(set) var readyVersion: String?
    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?

    /// Release builds carry a feed; development builds never replace themselves.
    var isAvailable: Bool { controller != nil }

    func start() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // A long-running menu bar app also looks once at launch.
        controller?.updater.checkForUpdatesInBackground()
    }
    /// The menu's Check for Updates…, with Sparkle's own progress window.
    func checkForUpdates() { controller?.checkForUpdates(nil) }
    /// Quietly, for example after the other Mac turned out to run a newer version.
    func checkInBackground() {
        guard let updater = controller?.updater, !updater.sessionInProgress else { return }
        updater.checkForUpdatesInBackground()
    }
    /// Installs a verified update if nothing would be interrupted.
    func installIfIdle() {
        if installNow != nil && isIdle() { install() }
    }
    /// Installs now and relaunches, even during a session.
    func install() {
        guard let installNow else { return }
        self.installNow = nil
        NativeLog.updates.notice("installing \(self.readyVersion ?? "update", privacy: .public) and relaunching")
        installNow()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        readyVersion = item.displayVersionString
        NativeLog.updates.notice("update \(item.displayVersionString, privacy: .public) downloaded and verified")
        onChange?()
        DispatchQueue.main.async { [weak self] in self?.installIfIdle() }
        return true
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        NativeLog.updates.notice("up to date")
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NativeLog.updates.notice("update check stopped: \(error.localizedDescription, privacy: .public)")
    }
    /// Updates install automatically, so Sparkle never needs to remind anyone.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
