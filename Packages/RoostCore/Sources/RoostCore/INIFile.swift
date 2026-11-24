import Foundation

/// Line-preserving editor for INI files like `~/.aws/config`, `~/.aws/credentials` and `.git/config`.
/// Edits touch only the lines they change, so comments and ordering survive.
public struct INIFile: Equatable, Sendable {
    private(set) var lines: [String]

    public init(text: String) {
        lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
    }

    public static func read(_ url: URL) throws -> INIFile {
        FileManager.default.fileExists(atPath: url.path) ? INIFile(text: try String(contentsOf: url, encoding: .utf8)) : INIFile(text: "")
    }

    public var text: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }

    public var sectionNames: [String] { lines.compactMap(Self.header) }

    /// Keys are lowercased; values are trimmed.
    public func values(in section: String) -> [String: String] {
        guard let range = range(of: section) else { return [:] }
        var values: [String: String] = [:]
        for line in lines[range] {
            if let (key, value) = Self.keyValue(line) { values[key.lowercased()] = value }
        }
        return values
    }

    public func hasSection(_ section: String) -> Bool { range(of: section) != nil }

    public mutating func set(_ key: String, _ value: String, in section: String) {
        let newLine = "\(key) = \(value)"
        guard let range = range(of: section) else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines += ["[\(section)]", newLine]
            return
        }
        if let index = range.first(where: { Self.keyValue(lines[$0])?.key.lowercased() == key.lowercased() }) {
            lines[index] = newLine
            return
        }
        // Insert after the section's last non-blank line, so blank separators stay at the end.
        let insertAt = (range.last(where: { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }) ?? range.lowerBound - 1) + 1
        lines.insert(newLine, at: insertAt)
    }

    public mutating func removeKey(_ key: String, in section: String) {
        guard let range = range(of: section) else { return }
        if let index = range.first(where: { Self.keyValue(lines[$0])?.key.lowercased() == key.lowercased() }) {
            lines.remove(at: index)
        }
    }

    @discardableResult
    public mutating func removeSection(_ section: String) -> Bool {
        guard let range = range(of: section) else { return false }
        lines.removeSubrange((range.lowerBound - 1)..<range.upperBound)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return true
    }

    /// The body lines of a section (header excluded).
    private func range(of section: String) -> Range<Int>? {
        guard let header = lines.firstIndex(where: { Self.header($0) == section }) else { return nil }
        let end = lines[(header + 1)...].firstIndex(where: { Self.header($0) != nil }) ?? lines.count
        return (header + 1)..<end
    }

    private static func header(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 else { return nil }
        return String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    private static func keyValue(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }
}
