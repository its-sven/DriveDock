import Foundation

/// Persists connection definitions (never passwords) as JSON in Application Support.
struct ConnectionStore {
    let fileURL: URL

    init(fileURL: URL = ConnectionStore.defaultURL) {
        self.fileURL = fileURL
    }

    static let defaultURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DriveDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
    }()

    /// Loads every entry that can be read. If the file or a single entry can't be decoded
    /// (damaged file, or written by a newer version), a copy of the file is kept next to it
    /// before the next save overwrites it – so no server definition is ever lost silently.
    func load() -> [Connection] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let entries = try? JSONDecoder().decode([Lenient<Connection>].self, from: data) else {
            backUp(reason: "the file could not be read")
            return []
        }
        let connections = entries.compactMap(\.value)
        if connections.count != entries.count {
            backUp(reason: "\(entries.count - connections.count) entries could not be read")
        }
        return connections
    }

    func save(_ connections: [Connection]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(connections).write(to: fileURL, options: .atomic)
        } catch {
            ActivityLog.write("Could not save the server list: \(error.localizedDescription)")
        }
    }

    private func backUp(reason: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let copy = fileURL.deletingLastPathComponent().appendingPathComponent("connections-\(stamp).json")
        try? FileManager.default.copyItem(at: fileURL, to: copy)
        ActivityLog.write("Server list: \(reason) – kept a copy at \(copy.path)")
    }
}

/// Decodes to nil instead of failing the whole array.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
