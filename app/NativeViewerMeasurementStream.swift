import Foundation

/// Event-driven delivery of live measurements. Producers never enqueue more
/// than one main-thread delivery. Painting is capped at 10 Hz; rates use a
/// rolling second. Two one-shot expirations clear idle rates and stale peer
/// data, then stop. There is no repeating UI timer or telemetry polling.
final class NativeViewerMeasurementStream: @unchecked Sendable {
    private let lock = NSLock()
    private let measurements: NativeSessionMeasurements
    private let onSample: (NativeInterval) -> Void
    private let minimumInterval: TimeInterval
    private let expirations: [TimeInterval]
    private var active = true
    private var pending: DispatchWorkItem?
    private var expiryWork: [DispatchWorkItem] = []
    private var changed = false
    private var lastDelivery: TimeInterval = 0
    /// Main-thread only, capped even if a future caller requests faster delivery.
    private var samples: [(at: TimeInterval, values: [String: Double])]

    init(measurements: NativeSessionMeasurements, minimumInterval: TimeInterval = 0.1,
         expirations: [TimeInterval] = [1.05, 3.05], onSample: @escaping (NativeInterval) -> Void) {
        self.measurements = measurements; self.onSample = onSample
        self.minimumInterval = max(0.01, minimumInterval)
        self.expirations = Array(expirations.prefix(2))
        samples = [(ProcessInfo.processInfo.systemUptime, measurements.snapshot())]
    }
    /// May be called by capture, decode, presentation or the receive thread.
    func signal() {
        lock.lock()
        if active { changed = true; enqueueLocked() }
        lock.unlock()
    }
    private func enqueueLocked() {
        guard active, pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.deliver() }
        pending = work
        let delay = max(0, lastDelivery + minimumInterval - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func expire() {
        lock.lock(); enqueueLocked(); lock.unlock()
    }
    private func deliver() {
        lock.lock()
        guard active else { lock.unlock(); return }
        pending = nil
        let rearm = changed; changed = false
        let now = ProcessInfo.processInfo.systemUptime
        lastDelivery = now
        lock.unlock()
        let values = measurements.snapshot()
        // Keep one baseline just before the rolling second when available.
        while samples.count > 1 && samples[1].at <= now - 1 { samples.removeFirst() }
        let baseline = samples[0]
        samples.append((now, values))
        if samples.count > 16 { samples.removeFirst(samples.count - 16) }
        onSample(NativeInterval(seconds: now - baseline.at, values: values, previous: baseline.values, maxima: [:]))
        guard rearm else { return }
        lock.lock()
        if active {
            for work in expiryWork { work.cancel() }
            expiryWork = expirations.map { delay in
                let work = DispatchWorkItem { [weak self] in self?.expire() }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                return work
            }
        }
        lock.unlock()
    }
    func stop() {
        lock.lock()
        active = false; pending?.cancel(); pending = nil
        for work in expiryWork { work.cancel() }
        expiryWork = []
        lock.unlock()
    }
    deinit { stop() }
}
