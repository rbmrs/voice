import Foundation

struct CommandResult {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32
}

struct ShellCommandRunner: Sendable {
    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        let executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)

        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw DictationServiceError.configuration("Executable not found or not runnable: \(executable)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    try process.run()
                    process.waitUntilExit()

                    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

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
