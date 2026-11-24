import Foundation

/// Roost's own saved projects, as JSON in Application Support. Holds no secrets.
public struct Store: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Roost/state.json")
    }

    public init(url: URL = Store.defaultURL) {
        self.url = url
    }

    /// A missing file is a first run, not an error.
    public func load() throws -> RoostState {
        guard FileManager.default.fileExists(atPath: url.path) else { return RoostState() }
        return try JSONDecoder().decode(RoostState.self, from: Data(contentsOf: url))
    }

    public func save(_ state: RoostState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
