import Foundation

/// One viewer's reconnect intent. Rust owns retry budgets; this workflow owns
/// scheduled effects, so cancellation also works with a non-Dispatch scheduler.
final class NativeReconnectWorkflow {
    struct Attempt {
        let number: Int
        let limit: Int
        let milliseconds: Int64
    }
    var attempts = 0
    var awaitingPeer = false
    private let scheduler: any ConnectionScheduling
    private var pending: NativeRunToken?
    var isPending: Bool { pending != nil }
    init(scheduler: any ConnectionScheduling) { self.scheduler = scheduler }

    func schedule(_ operation: @escaping () -> Void) -> Attempt? {
        let number = attempts + 1
        let milliseconds = awaitingPeer ? ml_update_reconnect_delay_ms(UInt32(number)) : ml_reconnect_delay_ms(UInt32(number))
        guard milliseconds >= 0 else { reset(); return nil }
        attempts = number
        cancelPending()
        let token = NativeRunToken()
        pending = token
        scheduler.after(Double(milliseconds) / 1_000) { [weak self] in
            guard let self, token.isActive, self.pending === token else { return }
            self.pending = nil
            operation()
        }
        return Attempt(number: number, limit: Int(awaitingPeer ? ML_UPDATE_RECONNECT_ATTEMPTS : ML_RECONNECT_ATTEMPTS),
                       milliseconds: Int64(milliseconds))
    }
    func cancelPending() { pending?.cancel(); pending = nil }
    func reset() { cancelPending(); attempts = 0; awaitingPeer = false }
}
