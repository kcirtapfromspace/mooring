import AppKit
import CoreGraphics

/// Best-effort local privacy boundary for the explicit-sharing prototype.
/// CGSessionCopyCurrentDictionary and NSWorkspace notifications are public APIs.
/// "CGSSessionScreenIsLocked" and "com.apple.screenIsLocked" are compatibility
/// signals, not documented Apple contracts. The lock flag is absent on this
/// machine when unlocked. Real lock/unlock testing on supported OS releases is
/// a release gate; absence of that field must not be described as proof of unlock.
/// An unsafe notification only ends a session. Unlock never resumes one.
final class NativePrivacyGuard {
    private let lock = NSLock()
    private var active = true
    private let onUnsafe: () -> Void
    private let workspaceCenter: NotificationCenter
    private let distributedCenter = DistributedNotificationCenter.default()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObserver: NSObjectProtocol?

    static func mayShareNow() -> Bool {
        sessionIsEligible(CGSessionCopyCurrentDictionary() as? [String: Any])
    }
    /// Automatic sharing may keep listening, but never capture, while this
    /// user's session is on the console with its display asleep or its screen
    /// covered or locked; an approved Mac's connection then wakes it.
    static func mayListenNow() -> Bool {
        sessionMayListen(CGSessionCopyCurrentDictionary() as? [String: Any])
    }
    /// Display sleep ends a session; a viewer's connection wakes the display.
    static var displayIsAwake: Bool { CGDisplayIsAsleep(CGMainDisplayID()) == 0 }
    /// Pure classifier used by permission-free tests. Missing/ill-typed public
    /// session state fails closed; any present lock flag must be exactly false.
    static func sessionIsEligible(_ session: [String: Any]?) -> Bool {
        guard let session,
              boolean(session[kCGSessionOnConsoleKey as String]) == true,
              boolean(session[kCGSessionLoginDoneKey as String]) == true else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] { return boolean(locked) == false }
        return true
    }
    /// As sessionIsEligible, whatever the lock flag says.
    static func sessionMayListen(_ session: [String: Any]?) -> Bool {
        guard let session else { return false }
        return boolean(session[kCGSessionOnConsoleKey as String]) == true
            && boolean(session[kCGSessionLoginDoneKey as String]) == true
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let value, CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    /// Instantiate on main with an idempotent stop-sharing callback. Notifications
    /// can only revoke the session, never start one or inject remote input.
    init(onUnsafe: @escaping () -> Void) {
        self.onUnsafe = onUnsafe
        workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main) { [weak self] _ in self?.unsafe() })
        distributedObserver = distributedCenter.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] _ in self?.unsafe() }
    }
    private func unsafe() {
        lock.lock(); let deliver = active; lock.unlock()
        if deliver { onUnsafe() }
    }
    func stop() {
        lock.lock()
        active = false
        let workspace = workspaceObservers, distributed = distributedObserver
        workspaceObservers = []; distributedObserver = nil
        lock.unlock()
        workspace.forEach { workspaceCenter.removeObserver($0) }
        if let distributed { distributedCenter.removeObserver(distributed) }
    }
    deinit { stop() }
}
