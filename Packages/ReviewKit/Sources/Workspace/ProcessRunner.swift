import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }
}

public struct ProcessError: Error, Sendable, CustomStringConvertible {
    public var tool: String
    public var result: ProcessResult

    public var description: String {
        if result.timedOut { return "\(tool) timed out" }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? ""
        return detail.isEmpty ? "\(tool) failed (exit \(result.status))" : "\(tool): \(detail)"
    }
}

/// Runs a program with an argument array. Never goes through a shell.
public struct ProcessRunner: Sendable {
    /// PATH for child processes. GUI apps launched at login do not inherit the login shell's PATH.
    public var path: String

    public init(extraPaths: [String] = []) {
        let standard = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        path = (extraPaths + standard).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    public func run(_ executable: URL, _ arguments: [String], in directory: URL? = nil, timeout: TimeInterval = 60) async throws -> ProcessResult {
        let path = path
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = path
                // Never block on a credential prompt nobody can see.
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["GH_PROMPT_DISABLED"] = "1"
                process.environment = environment
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice

                let group = DispatchGroup()
                let box = OutputBox()
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                group.enter()
                DispatchQueue.global().async { box.setOut(out.fileHandleForReading.readDataToEndOfFile()); group.leave() }
                group.enter()
                DispatchQueue.global().async { box.setErr(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }

                let timer = DispatchWorkItem { if process.isRunning { box.markTimedOut(); process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                process.waitUntilExit()
                timer.cancel()
                group.wait()
                continuation.resume(returning: ProcessResult(
                    status: process.terminationStatus,
                    stdout: String(decoding: box.out, as: UTF8.self),
                    stderr: String(decoding: box.err, as: UTF8.self),
                    timedOut: box.timedOut))
            }
        }
    }

    /// Runs and throws `ProcessError` on a non-zero exit.
    @discardableResult
    public func check(_ executable: URL, _ arguments: [String], in directory: URL? = nil, timeout: TimeInterval = 60) async throws -> String {
        let result = try await run(executable, arguments, in: directory, timeout: timeout)
        guard result.succeeded else { throw ProcessError(tool: executable.lastPathComponent, result: result) }
        return result.stdout
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var out = Data()
    private(set) var err = Data()
    private(set) var timedOut = false

    func setOut(_ data: Data) { lock.withLock { out = data } }
    func setErr(_ data: Data) { lock.withLock { err = data } }
    func markTimedOut() { lock.withLock { timedOut = true } }
}
