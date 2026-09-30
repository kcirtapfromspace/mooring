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
    /// The same, as a comparable version for a viewer that asked.
    private(set) var readyNativeVersion: NativeVersion?
    /// Progress of a check a viewer asked for, reported until it resolves.
    var onViewerStatus: ((NativeUpdateState, NativeVersion?) -> Void)?
    /// Called just before a verified update installs and MacLink relaunches.
    var willInstall: (() -> Void)?
    private var viewerAsked = false
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
    /// A viewer asked: check now and report checking, then up to date, ready
    /// or failed. A verified update already waiting is reported at once.
    func checkForViewer() {
        if let ready = readyNativeVersion { onViewerStatus?(.ready, ready); return }
        guard let updater = controller?.updater else { onViewerStatus?(.failed, nil); return }
        viewerAsked = true
        onViewerStatus?(.checking, nil)
        if !updater.sessionInProgress { updater.checkForUpdatesInBackground() }
    }
    private func reportToViewer(_ state: NativeUpdateState, _ ready: NativeVersion? = nil) {
        guard viewerAsked else { return }
        viewerAsked = false
        onViewerStatus?(state, ready)
    }
    /// Installs a verified update if nothing would be interrupted.
    func installIfIdle() {
        if installNow != nil && isIdle() { install() }
    }
    /// Installs now and relaunches, even during a session.
    func install() {
        guard let installNow else { return }
        self.installNow = nil
        willInstall?()
        NativeLog.updates.notice("installing \(self.readyVersion ?? "update", privacy: .public) and relaunching")
        installNow()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installNow = immediateInstallHandler
        readyVersion = item.displayVersionString
        var release: UInt64 = 0
        if ml_release_pack(item.displayVersionString, &release) != ML_SESSION_OK { release = 0 }
        let ready = NativeVersion(build: max(1, UInt32(item.versionString) ?? 1), release: release)
        readyNativeVersion = ready
        // A viewer is told the update is ready even if it asked before; it
        // installs once no session is connected.
        viewerAsked = false
        onViewerStatus?(.ready, ready)
        NativeLog.updates.notice("update \(item.displayVersionString, privacy: .public) downloaded and verified")
        onChange?()
        DispatchQueue.main.async { [weak self] in self?.installIfIdle() }
        return true
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        NativeLog.updates.notice("up to date")
        reportToViewer(.upToDate)
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NativeLog.updates.notice("update check stopped: \(error.localizedDescription, privacy: .public)")
        // Sparkle also ends a check that found nothing this way.
        let nsError = error as NSError
        let upToDate = nsError.domain == SUSparkleErrorDomain && nsError.code == Int(SUError.noUpdateError.rawValue)
        reportToViewer(upToDate ? .upToDate : .failed)
    }
    /// Every check ends here, including one that showed Sparkle's own window;
    /// a viewer still waiting hears how it ended.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        reportToViewer(error == nil ? .upToDate : .failed)
    }
    /// Updates install automatically, so Sparkle never needs to remind anyone.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
