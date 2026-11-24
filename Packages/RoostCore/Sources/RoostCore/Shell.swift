import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public var succeeded: Bool { status == 0 }
}

public typealias LineSink = @Sendable (String) async -> Void

/// Runs command-line tools. Every command is echoed to `onLine` as `$ …` before it runs, so the user sees exactly what happens.
public enum Shell {
    // A GUI app starts with a minimal PATH; Homebrew tools and the claude CLI live outside it.
    static var searchPath: String {
        "\(Paths.home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// The command as shown in the log; any `redacting` values (secrets inside arguments) are masked.
    public static func describe(_ tool: String, _ arguments: [String], redacting secrets: [String] = []) -> String {
        var line = ([tool] + arguments).map(quote).joined(separator: " ")
        for secret in secrets where !secret.isEmpty { line = line.replacingOccurrences(of: secret, with: "•••") }
        return line
    }

    static func quote(_ argument: String) -> String {
        let needsQuotes = argument.isEmpty || argument.contains { " '\"$\\*?;&|<>()".contains($0) }
        guard needsQuotes else { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    public static func run(
        _ tool: String,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        redacting secrets: [String] = [],
        onLine: LineSink? = nil
    ) async throws -> CommandResult {
        await onLine?("$ " + describe(tool, arguments, redacting: secrets))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        var processEnvironment = ProcessInfo.processInfo.environment
        processEnvironment["PATH"] = searchPath
        processEnvironment.merge(environment) { _, override in override }
        process.environment = processEnvironment
        if let directory { process.currentDirectoryURL = directory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        // waitUntilExit() spins a run loop, which Swift's async threads don't have, and can hang after the child exits.
        // The exit status is handed over through a stream set up before launch, so an early exit isn't missed.
        let (exits, exitContinuation) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { finished in
            exitContinuation.yield(finished.terminationStatus)
            exitContinuation.finish()
        }
        try process.run()
        var lines: [String] = []
        for try await line in pipe.fileHandleForReading.bytes.lines {
            lines.append(line)
            await onLine?(line)
        }
        var status: Int32 = -1
        for await exitStatus in exits { status = exitStatus }
        return CommandResult(status: status, output: lines.joined(separator: "\n"))
    }

    /// Like `run`, but a non-zero exit throws `RoostError.commandFailed`.
    @discardableResult
    public static func runChecked(
        _ tool: String,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        redacting secrets: [String] = [],
        onLine: LineSink? = nil
    ) async throws -> CommandResult {
        let result = try await run(tool, arguments, in: directory, environment: environment, redacting: secrets, onLine: onLine)
        guard result.succeeded else {
            throw RoostError.commandFailed(
                command: describe(tool, arguments, redacting: secrets), status: result.status, output: result.output
            )
        }
        return result
    }
}
