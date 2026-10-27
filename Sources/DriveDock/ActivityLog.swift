import Foundation

/// Plain-text log at ~/Library/Logs/DriveDock.log (opens in Console.app), so connection
/// problems can be traced afterwards. Kept small by rotating at 1 MB.
enum ActivityLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DriveDock.log")

    private static let queue = DispatchQueue(label: "DriveDock.ActivityLog")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        f.timeZone = .current
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
                try? fm.removeItem(at: url.appendingPathExtension("old"))
                try? fm.moveItem(at: url, to: url.appendingPathExtension("old"))
            }
            guard let data = line.data(using: .utf8) else { return }
            // The throwing FileHandle API: the old seekToEndOfFile()/write(_:) raise an
            // Objective-C exception on I/O errors (e.g. a full disk) and crash the app.
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
