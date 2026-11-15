import Foundation

private final class TunnelErrorOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes.append(data.prefix(max(0, 16_384 - bytes.count)))
    }
    var message: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs `mooring connect ID` for saved connections that go through SSH.
///
/// Rust owns the tunnel: SSH options, the 127.0.0.1 listener, the RFB check,
/// timeouts, retries and teardown. This shell only starts that process, reads
/// its JSON lines and asks it to stop. Rust also stops on its own when the
/// session ends, or when this app exits for any reason.
final class SSHTunnels: TunnelRunning {
    private var running: [String: Process] = [:]
    /// One JSON event from a tunnel, delivered on the main thread.
    var onEvent: ((SavedMac, TunnelEvent) -> Void)?
    /// The tunnel process exited; delivered on the main thread after its last event.
    var onExit: ((SavedMac, Int32, String) -> Void)?

    func isRunning(_ id: String) -> Bool { running[id] != nil }

    /// `extraArguments` follow `connect ID`, for example `--no-viewer` when
    /// Mooring's own viewer connects instead of Screen Sharing.
    func open(_ mac: SavedMac, executable: URL, extraArguments: [String] = []) throws {
        guard running[mac.id] == nil else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["connect", mac.id] + extraArguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        running[mac.id] = process
        let reader = output.fileHandleForReading, errorReader = errors.fileHandleForReading
        // Drain both pipes concurrently. Taking a prefix after reading all of
        // stderr neither bounds memory nor prevents a full-pipe deadlock.
        let errorOutput = TunnelErrorOutput(), errorDone = DispatchGroup()
        errorDone.enter()
        Thread.detachNewThread {
            defer { errorDone.leave() }
            while true {
                let data = errorReader.availableData
                if data.isEmpty { break }
                errorOutput.append(data)
            }
        }
        Thread.detachNewThread { [weak self] in
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    do {
                        let event = try TunnelEvent.decode(line)
                        DispatchQueue.main.async {
                            guard self?.running[mac.id] === process else { return }
                            self?.onEvent?(mac, event)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            guard self?.running[mac.id] === process else { return }
                            self?.onEvent?(mac, .failed(ConnectionFailure(kind: "invalid_event", message: "The Mooring command returned an invalid connection event.")))
                            self?.stop(mac.id)
                        }
                    }
                }
                // Events are small; a runaway line is dropped, not buffered.
                if buffer.count > 262_144 { buffer.removeAll() }
            }
            process.waitUntilExit()
            errorDone.wait()
            let message = errorOutput.message
            DispatchQueue.main.async {
                guard self?.running[mac.id] === process else { return }
                self?.running[mac.id] = nil
                self?.onExit?(mac, process.terminationStatus, message)
            }
        }
    }

    /// SIGTERM: Rust closes the viewer sockets, stops every ssh and exits.
    func stop(_ id: String) {
        if let process = running[id], process.isRunning { process.terminate() }
    }

    /// Called when the app quits. Waits briefly so teardown finishes first.
    func stopAll(wait: TimeInterval = 2) {
        let processes = Array(running.values)
        processes.forEach { if $0.isRunning { $0.terminate() } }
        let deadline = Date().addingTimeInterval(wait)
        while processes.contains(where: { $0.isRunning }) && Date() < deadline { usleep(20_000) }
    }
}
