// Pure classification only: never observes, posts, locks, or captures a session.
import Foundation
import CoreGraphics

@main
struct NativePrivacyTests {
    static func main() {
        let console = kCGSessionOnConsoleKey as String, login = kCGSessionLoginDoneKey as String
        let lock = "CGSSessionScreenIsLocked"
        let cases: [([String: Any]?, Bool)] = [
            (nil, false), ([:], false), ([console: true], false), ([login: true], false),
            ([console: false, login: true], false), ([console: true, login: false], false),
            ([console: true, login: true], true), // absent compatibility flag on unlocked macOS
            ([console: true, login: true, lock: false], true),
            ([console: true, login: true, lock: true], false),
            ([console: "true", login: true], false), ([console: 1, login: true], false),
            ([console: true, login: NSNull()], false),
            ([console: true, login: true, lock: 0], false),
            ([console: true, login: true, lock: "false"], false),
            ([console: true, login: true, lock: NSNull()], false)
        ]
        for (index, test) in cases.enumerated() {
            guard NativePrivacyGuard.sessionIsEligible(test.0) == test.1 else {
                fputs("Native privacy classification failed at case \(index).\n", stderr); exit(1)
            }
        }
        // Listening ignores the lock flag, but never a session off the console
        // or not yet logged in.
        let listening: [([String: Any]?, Bool)] = [
            (nil, false), ([:], false), ([console: true], false), ([login: true], false),
            ([console: false, login: true, lock: false], false), ([console: true, login: false], false),
            ([console: true, login: true], true), ([console: true, login: true, lock: false], true),
            ([console: true, login: true, lock: true], true), ([console: true, login: true, lock: NSNull()], true),
            ([console: "true", login: true], false), ([console: true, login: 1], false)
        ]
        for (index, test) in listening.enumerated() {
            guard NativePrivacyGuard.sessionMayListen(test.0) == test.1 else {
                fputs("Native privacy listening classification failed at case \(index).\n", stderr); exit(1)
            }
        }
        print("NativePrivacyGuard: \(cases.count + listening.count) pure checks passed; no live lock/unlock or notification behavior tested.")
    }
}
