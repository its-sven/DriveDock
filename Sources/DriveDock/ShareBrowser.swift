import Foundation

/// Lists the shares a server offers to the profile's login, via `smbutil view`.
enum ShareBrowser {
    struct Share: Hashable {
        let name: String
        let comment: String
        /// Administrative / hidden shares such as C$ or ADMIN$.
        var isHidden: Bool { name.hasSuffix("$") }
    }

    struct BrowseError: LocalizedError {
        let message: String
        var isAuthFailure = false
        var errorDescription: String? { message }
    }

    /// Blocking; call from a background task.
    static func list(_ c: Connection, host: String, password: String?) throws -> [Share] {
        let result: ToolRunner.Result
        if c.needsPassword {
            // Same rule as for mounting (see Connection.connectsByIP). -f: own session.
            result = ToolRunner.runWithPassword(
                "/usr/bin/smbutil", ["view", "-f", Mounter.smbURL(for: c, host: host, share: nil)],
                password: password ?? "", timeout: 25)
        } else {
            result = ToolRunner.run("/usr/bin/smbutil", ["view", "-N", "//\(host)"], timeout: 25)
        }
        if result.timedOut {
            throw BrowseError(message: tr("Server not responding (timeout)"))
        }
        if result.passwordRejected || result.output.lowercased().contains("authentication error") {
            throw BrowseError(message: tr("Login failed – check user and password"), isAuthFailure: true)
        }
        guard result.status == 0 else {
            let message = result.output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty } ?? tr("smbutil error %lld", Int(result.status))
            throw BrowseError(message: message.replacingOccurrences(of: "smbutil: ", with: ""))
        }
        return parse(result.output)
    }

    static func parse(_ output: String) -> [Share] {
        // Lines look like "EDV        Disk    Comment"; names may contain spaces and the
        // column padding is off for non-ASCII names, so split on the type column.
        let pattern = try! NSRegularExpression(pattern: #"^(.+?)\s+(Disk|Printer|Pipe|Device)\b\s*(.*)$"#)
        var shares: [Share] = []
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(line.startIndex..., in: line)
            guard let m = pattern.firstMatch(in: line, range: range),
                  let name = Range(m.range(at: 1), in: line).map({ String(line[$0]) }),
                  let type = Range(m.range(at: 2), in: line).map({ String(line[$0]) }),
                  type == "Disk",
                  name != "Share" else { continue }
            let comment = Range(m.range(at: 3), in: line).map { String(line[$0]) } ?? ""
            shares.append(Share(name: name.trimmingCharacters(in: .whitespaces), comment: comment))
        }
        return shares.sorted {
            $0.isHidden == $1.isHidden
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : !$0.isHidden
        }
    }
}
