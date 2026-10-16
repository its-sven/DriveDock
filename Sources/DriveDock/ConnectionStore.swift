import Foundation

/// Persists connection definitions (never passwords) as JSON in Application Support.
struct ConnectionStore {
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DriveDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("connections.json")
    }()

    func load() -> [Connection] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([Connection].self, from: data)
        } catch {
            NSLog("DriveDock: could not read %@: %@", fileURL.path, error.localizedDescription)
            return []
        }
    }

    func save(_ connections: [Connection]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(connections).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("DriveDock: could not write %@: %@", fileURL.path, error.localizedDescription)
        }
    }
}
