import Foundation

struct CommandResult {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32
}

struct ShellCommandRunner: Sendable {
    func run(executable: String, arguments: [String], timeout: TimeInterval? = nil) async throws -> CommandResult {
        let executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = URL(fileURLWithPath: executable).lastPathComponent

        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw DictationServiceError.configuration("Executable not found or not runnable: \(executable)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    let stdinPipe = Pipe()
                    stdinPipe.fileHandleForWriting.closeFile()
                    process.standardInput = stdinPipe

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    let group = DispatchGroup()
                    let stdoutBuffer = OutputBuffer()
                    let stderrBuffer = OutputBuffer()
                    let timeoutState = TimeoutState()

                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        stdoutBuffer.store(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                        group.leave()
                    }

                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        stderrBuffer.store(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                        group.leave()
                    }

                    try process.run()

                    if let timeout {
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                            guard process.isRunning else { return }
                            timeoutState.markTimedOut()
                            process.terminate()
                        }
                    }

                    process.waitUntilExit()
                    group.wait()

                    if let timeout, timeoutState.isTimedOut {
                        throw DictationServiceError.processFailure(
                            tool: toolName,
                            details: "Timed out after \(Int(timeout)) seconds."
                        )
                    }

                    let stdout = String(data: stdoutBuffer.snapshot(), encoding: .utf8) ?? ""
                    let stderr = String(data: stderrBuffer.snapshot(), encoding: .utf8) ?? ""

                    continuation.resume(returning: CommandResult(
                        standardOutput: stdout,
                        standardError: stderr,
                        exitCode: process.terminationStatus
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var isTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }
}
