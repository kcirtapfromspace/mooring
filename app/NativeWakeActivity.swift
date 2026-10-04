import Foundation
import IOKit.pwr_mgt

/// Main-thread public power API boundary for one authenticated wake attempt.
/// Hold the display through the short handshake; release on success, failure
/// or cancellation. The hold also expires in powerd if our queue is stalled.
final class NativeWakeActivity {
    private var displayHold: IOPMAssertionID?
    private var activity: IOPMAssertionID?
    private var stopped = false
    private let declare: (inout IOPMAssertionID) -> Bool
    private let release: (IOPMAssertionID) -> Void

    init(createHold: () -> IOPMAssertionID? = NativeWakeActivity.createDisplayHold,
         declare: @escaping (inout IOPMAssertionID) -> Bool = NativeWakeActivity.declareRemoteActivity,
         release: @escaping (IOPMAssertionID) -> Void = { _ = IOPMAssertionRelease($0) }) {
        self.declare = declare; self.release = release
        displayHold = createHold()
    }

    @discardableResult func request() -> Bool {
        guard !stopped else { return false }
        // IOKit may replace the ID on each successful renewal. A failed call
        // must not discard the last valid ID, even if it writes its output.
        var next = activity ?? 0
        guard declare(&next) else { return false }
        activity = next
        return true
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let activity { release(activity) }
        if let displayHold { release(displayHold) }
        activity = nil; displayHold = nil
    }
    deinit { stop() }

    private static func createDisplayHold() -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithDescription(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            "A paired Mac is waiting for this display" as CFString, nil, nil, nil,
            Double(ML_HOST_WAKE_WAIT_MS) / 1000, kIOPMAssertionTimeoutActionRelease as CFString, &id)
        return status == kIOReturnSuccess ? id : nil
    }
    private static func declareRemoteActivity(_ id: inout IOPMAssertionID) -> Bool {
        IOPMAssertionDeclareUserActivity("A paired Mac is connecting" as CFString,
                                       kIOPMUserActiveRemote, &id) == kIOReturnSuccess
    }
}
