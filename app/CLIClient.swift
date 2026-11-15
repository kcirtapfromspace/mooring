import Foundation

struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    func expire() { lock.lock(); expired = true; lock.unlock() }
    var isExpired: Bool { lock.lock(); defer { lock.unlock() }; return expired }
}

/// The UI only launches the CLI. Connection storage, validation and probing live in Rust.
final class CLIClient {
    func run(_ arguments: [String], timeout: TimeInterval = 15,
             completion: @escaping (Result<Data, CLIError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Data, CLIError>
            do {
                let data = try self.execute(arguments, timeout: timeout)
                result = .success(data)
            } catch {
                result = .failure(CLIError(message: error.localizedDescription))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func executableURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["MOORING_BIN"], !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw CLIError(message: "MOORING_BIN does not point to an executable: \(override)")
            }
            return URL(fileURLWithPath: override)
        }
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("mooring"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mooring")
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CLIError(message: "The Mooring command-line tool is missing. Rebuild the app with scripts/build-app.sh.")
        }
        return url
    }

    private func execute(_ arguments: [String], timeout: TimeInterval) throws -> Data {
        let binary = try executableURL()
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("mooring-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        for url in [outputURL, errorURL] {
            guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CLIError(message: "Could not create temporary command output.")
            }
        }
        let stdout = try FileHandle(forWritingTo: outputURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let timeoutState = TimeoutState()
        let deadline = DispatchWorkItem {
            if process.isRunning {
                timeoutState.expire()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        if timeoutState.isExpired {
            throw CLIError(message: "This operation took too long and was stopped. Check the Mac’s address and network, then try again.")
        }
        if process.terminationStatus != 0 {
            let data = (try? Data(contentsOf: errorURL)) ?? Data()
            let message = String(decoding: data.prefix(16_384), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(message: message.isEmpty ? "The Mooring command-line tool exited unexpectedly (\(process.terminationStatus))." : message)
        }
        return try Data(contentsOf: outputURL)
    }
}
