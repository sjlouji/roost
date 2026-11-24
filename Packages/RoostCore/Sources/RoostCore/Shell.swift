import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public var succeeded: Bool { status == 0 }
}

public typealias LineSink = @Sendable (String) async -> Void

/// Runs command-line tools. Every command is echoed to `onLine` as `$ …` before it runs, so the user sees exactly what happens.
public enum Shell {
    // A GUI app starts with a minimal PATH; Homebrew tools live outside it.
    static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static func describe(_ tool: String, _ arguments: [String]) -> String {
        ([tool] + arguments).map(quote).joined(separator: " ")
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
        onLine: LineSink? = nil
    ) async throws -> CommandResult {
        await onLine?("$ " + describe(tool, arguments))
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
        try process.run()
        var lines: [String] = []
        for try await line in pipe.fileHandleForReading.bytes.lines {
            lines.append(line)
            await onLine?(line)
        }
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: lines.joined(separator: "\n"))
    }

    /// Like `run`, but a non-zero exit throws `RoostError.commandFailed`.
    @discardableResult
    public static func runChecked(
        _ tool: String,
        _ arguments: [String],
        in directory: URL? = nil,
        environment: [String: String] = [:],
        onLine: LineSink? = nil
    ) async throws -> CommandResult {
        let result = try await run(tool, arguments, in: directory, environment: environment, onLine: onLine)
        guard result.succeeded else {
            throw RoostError.commandFailed(command: describe(tool, arguments), status: result.status, output: result.output)
        }
        return result
    }
}
