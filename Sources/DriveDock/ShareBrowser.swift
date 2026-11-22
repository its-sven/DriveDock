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
            result = ToolRunner.run("/usr/bin/smbutil", ["view", "-N", Mounter.smbURL(for: c, host: host, share: nil)], timeout: 25)
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
        let shares = parse(result.output)
        // A server that answers without any listable share is far more likely a listing we
        // couldn't read than a server without shares: report it instead of an empty list,
        // which would make an "all shares" profile unmount everything.
        if shares.isEmpty {
            ActivityLog.write("Share list from \(host) could not be read (\(result.output.utf8.count) bytes):\n"
                + result.output.split(separator: "\n").prefix(6).map { "    " + $0 }.joined(separator: "\n"))
            throw BrowseError(message: tr("The server's share list could not be read"))
        }
        return shares
    }

    /// Parses `smbutil view` output:
    ///
    ///     Share                                           Type    Comments
    ///     -------------------------------
    ///     EDV                                             Disk    IT department
    ///
    /// smbutil pads the share column to a fixed number of *bytes*, so the name is everything
    /// before the byte column of "Type" in the header. Splitting at the first type word instead
    /// breaks names like "USB Disk"; counting characters breaks names with umlauts or dashes.
    static func parse(_ output: String) -> [Share] {
        let lines = output.components(separatedBy: .newlines)
        guard let headerIndex = lines.firstIndex(where: { $0.hasPrefix("Share") && $0.contains("Type") }),
              let typeRange = lines[headerIndex].range(of: "Type") else { return [] }
        let header = lines[headerIndex]
        let typeColumn = header.utf8.distance(from: header.startIndex, to: typeRange.lowerBound)
        let types: Set<String> = ["Disk", "Printer", "Pipe", "Device"]

        var shares: [Share] = []
        for line in lines[(headerIndex + 1)...] {
            let bytes = Array(line.utf8)
            let name: String
            let rest: String
            if bytes.count > typeColumn, bytes[typeColumn - 1] == UInt8(ascii: " ") {
                name = String(decoding: bytes[..<typeColumn], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                rest = String(decoding: bytes[typeColumn...], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            } else if let overflow = splitOverlongLine(line, types: types) {
                // A name longer than the column pushes the type to the right.
                (name, rest) = overflow
            } else {
                continue
            }
            let type = rest.prefix { !$0.isWhitespace }
            guard !name.isEmpty, types.contains(String(type)), type == "Disk" else { continue }
            let comment = rest.dropFirst(type.count).trimmingCharacters(in: .whitespaces)
            shares.append(Share(name: name, comment: comment))
        }
        return shares.sorted {
            $0.isHidden == $1.isHidden
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : !$0.isHidden
        }
    }

    private static func splitOverlongLine(_ line: String, types: Set<String>) -> (String, String)? {
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let index = words.firstIndex(where: { types.contains(String($0)) }), index > 0 else { return nil }
        let nameEnd = line.range(of: " " + words[index])!.lowerBound
        return (String(line[..<nameEnd]).trimmingCharacters(in: .whitespaces),
                String(line[nameEnd...]).trimmingCharacters(in: .whitespaces))
    }
}
