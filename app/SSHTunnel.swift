import Foundation

/// Runs `mooring connect ID` for saved connections that go through SSH.
///
/// Rust owns the tunnel: SSH options, the 127.0.0.1 listener, the RFB check,
/// timeouts, retries and teardown. This shell only starts that process, reads
/// its JSON lines and asks it to stop. Rust also stops on its own when the
/// session ends, or when this app exits for any reason.
final class SSHTunnels {
    private var running: [String: Process] = [:]
    /// One JSON event from a tunnel, delivered on the main thread.
    var onEvent: ((SavedMac, [String: Any]) -> Void)?
    /// The tunnel process exited; delivered on the main thread after its last event.
    var onExit: ((SavedMac, Int32, String) -> Void)?

    func isRunning(_ id: String) -> Bool { running[id] != nil }

    func open(_ mac: SavedMac, executable: URL) throws {
        guard running[mac.id] == nil else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["connect", mac.id]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        running[mac.id] = process
        let reader = output.fileHandleForReading, errorReader = errors.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            var buffer = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                        DispatchQueue.main.async { self?.onEvent?(mac, event) }
                    }
                }
                // Events are small; a runaway line is dropped, not buffered.
                if buffer.count > 262_144 { buffer.removeAll() }
            }
            let message = String(decoding: errorReader.readDataToEndOfFile().prefix(16_384), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            process.waitUntilExit()
            DispatchQueue.main.async {
                self?.running[mac.id] = nil
                self?.onExit?(mac, process.terminationStatus, message)
            }
        }
    }

    /// SIGTERM: Rust closes the viewer sockets, stops every ssh and exits.
    func stop(_ id: String) { running[id]?.terminate() }

    /// Called when the app quits. Waits briefly so teardown finishes first.
    func stopAll(wait: TimeInterval = 2) {
        let processes = Array(running.values)
        processes.forEach { if $0.isRunning { $0.terminate() } }
        let deadline = Date().addingTimeInterval(wait)
        while processes.contains(where: { $0.isRunning }) && Date() < deadline { usleep(20_000) }
    }
}
