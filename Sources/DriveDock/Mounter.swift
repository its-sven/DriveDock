import Foundation
import NetFS

struct MountError: LocalizedError {
    let code: Int32
    /// Original tool message for errors without a specific text.
    var detail: String?

    var isAuthFailure: Bool {
        // EAUTH, EACCES, EPERM and NetAuth's "bad credentials" style codes.
        [EAUTH, EACCES, EPERM, -5045, -5023].contains(code)
    }

    var errorDescription: String? {
        switch code {
        case EACCES, EPERM: tr("Access denied")
        case EAUTH, -5045, -5023: tr("Login failed")
        case ENOENT: tr("Share not found")
        case EEXIST: tr("Already connected elsewhere")
        case ETIMEDOUT: tr("Server not responding (timeout)")
        case ECONNREFUSED: tr("Connection refused")
        case EHOSTUNREACH, ENETUNREACH: tr("Server not reachable")
        case -6003: tr("Cancelled")
        default:
            detail ?? (code > 0
                ? tr("Error %lld: %@", Int(code), String(cString: strerror(code)))
                : tr("Error %lld", Int(code)))
        }
    }
}

enum Mounter {
    /// Builds e.g. smb://FIRMA;user@server/Daten. The password is passed separately.
    static func url(for c: Connection, host: String, share: String) -> URL? {
        var userAllowed = CharacterSet.urlUserAllowed
        userAllowed.remove(charactersIn: ";:@")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: userAllowed) ?? s }

        var s = "\(c.kind.scheme)://"
        if c.kind == .smb, !c.username.isEmpty {
            s += c.domain.isEmpty ? enc(c.username) : "\(enc(c.domain));\(enc(c.username))"
            s += "@"
        }
        s += host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        if let port = c.port { s += ":\(port)" }
        let path = Connection.normalizedShare(share)
        s += "/" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
        return URL(string: s)
    }

    /// //[domain;]user@host[:port]/share as mount_smbfs and smbutil expect it. Without a user
    /// (Kerberos mode) the Mac's own ticket is used.
    static func smbURL(for c: Connection, host: String, share: String?) -> String {
        var userAllowed = CharacterSet.urlUserAllowed
        userAllowed.remove(charactersIn: ";:@")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: userAllowed) ?? s }

        // By IP the Mac's Kerberos ticket can't take over the login (see Connection.connectsByIP).
        let address = c.connectsByIP ? (resolveIPv4(host) ?? host) : host
        var s = "//"
        if c.needsPassword, !c.username.isEmpty {
            s += c.domain.isEmpty ? enc(c.username) : "\(enc(c.domain));\(enc(c.username))"
            s += "@"
        }
        s += address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        if let port = c.port { s += ":\(port)" }
        if let share {
            let path = Connection.normalizedShare(share)
            s += "/" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
        }
        return s
    }

    /// Blocking; call from a background task.
    static func mount(_ c: Connection, share: String, host: String, password: String?, at mountPoint: URL) throws {
        if c.kind == .smb {
            try mountSMB(c, share: share, host: host, password: password, at: mountPoint)
            return
        }
        var host = host
        let forcePassword = c.kind == .smb && c.authMode == .password
        if c.connectsByIP {
            // A domain-joined Mac otherwise silently logs in with its Kerberos ticket
            // (the Mac user) and ignores the given credentials. Kerberos needs the
            // server's name for its service ticket, so connecting by IP forces NTLM.
            host = resolveIPv4(host) ?? host
        }
        guard let url = url(for: c, host: host, share: share) else { throw MountError(code: EINVAL) }
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let openOptions = NSMutableDictionary()
        openOptions["UIOption"] = "NoUI"                // kNAUIOptionKey / kNAUIOptionNoUI
        openOptions["ForceNewSession"] = true           // kNetFSForceNewSessionKey: separate session per user
        if forcePassword {
            openOptions["UseAuthenticationInfo"] = false // kNetFSUseAuthenticationInfoKey
            openOptions["Kerberos"] = false              // kNetFSUseKerberosKey (legacy name)
        }

        let mountOptions = NSMutableDictionary()
        mountOptions["MountAtMountDir"] = true          // kNetFSMountAtMountDirKey: mount exactly at mountPoint
        mountOptions["SoftMount"] = true                // kNetFSSoftMountKey: fail instead of hanging when the server is gone
        // Keep Finder from adding every share under "Orte"; the profile folder in the
        // sidebar is the entry point instead.
        mountOptions["MountFlags"] = MNT_DONTBROWSE     // kNetFSMountFlagsKey

        // SMB takes the user (incl. domain) from the URL; WebDAV needs it as a parameter.
        let user: String? = c.kind == .smb ? nil : c.username

        // Async + cancel instead of NetFSMountURLSync: for shares the user may not open,
        // Windows sometimes never answers and the sync call would hang forever.
        final class Outcome: @unchecked Sendable { var status: Int32 = 0 }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        var requestID: AsyncRequestID?
        let rc = NetFSMountURLAsync(
            url as CFURL,
            mountPoint as CFURL,
            user as CFString?,
            password as CFString?,
            openOptions as CFMutableDictionary,
            mountOptions as CFMutableDictionary,
            &requestID,
            DispatchQueue.global(qos: .utility)
        ) { status, _, _ in
            outcome.status = status
            done.signal()
        }
        if rc != 0 {
            removeIfEmpty(mountPoint)
            throw MountError(code: rc)
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            if let requestID { NetFSMountURLCancel(requestID) }
            removeIfEmpty(mountPoint)
            throw MountError(code: ETIMEDOUT)
        }
        if outcome.status != 0 {
            removeIfEmpty(mountPoint)
            throw MountError(code: outcome.status)
        }
    }

    static let timeout: TimeInterval = 20

    /// SMB goes through mount_smbfs instead of NetFS: NetFS hands every mount to the
    /// NetAuthSysAgent, which can hang for shares the user may not open and then blocks all
    /// further mounts on the Mac. It also silently falls back to guest when the login fails.
    /// mount_smbfs answers such cases right away with a clear error.
    private static func mountSMB(_ c: Connection, share: String, host: String, password: String?, at mountPoint: URL) throws {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        // -s: own session, so several users can use the same server.
        // nobrowse: Finder doesn't list every share under "Orte"; the profile folder is the entry point.
        // soft: fail instead of hanging when the server goes away.
        let args = ["-s", "-o", "nobrowse,soft", smbURL(for: c, host: host, share: share), mountPoint.path]
        let result = c.needsPassword
            ? ToolRunner.runWithPassword("/sbin/mount_smbfs", args, password: password ?? "", timeout: timeout)
            : ToolRunner.run("/sbin/mount_smbfs", ["-N"] + args, timeout: timeout)
        if result.status == 0, MountTable.isMounted(mountPoint) { return }
        removeIfEmpty(mountPoint)
        throw error(from: result)
    }

    private static func error(from result: ToolRunner.Result) -> MountError {
        let text = result.output.lowercased()
        if result.timedOut { return MountError(code: ETIMEDOUT) }
        if result.passwordRejected || text.contains("authentication error") { return MountError(code: EAUTH) }
        if text.contains("permission denied") || text.contains("access denied") { return MountError(code: EACCES) }
        if text.contains("no such file") || text.contains("does not exist") || text.contains("not found") {
            return MountError(code: ENOENT)
        }
        if text.contains("file exists") || text.contains("already mounted") { return MountError(code: EEXIST) }
        if text.contains("connection refused") { return MountError(code: ECONNREFUSED) }
        if text.contains("host is down") || text.contains("no route") || text.contains("unreachable") {
            return MountError(code: EHOSTUNREACH)
        }
        let line = result.output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }?
            .replacingOccurrences(of: "mount_smbfs: ", with: "")
        return MountError(code: EIO, detail: line ?? tr("mount_smbfs error %lld", Int(result.status)))
    }

    static func resolveIPv4(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func unmount(at mountPoint: URL, completion: @escaping (Error?) -> Void) {
        FileManager.default.unmountVolume(at: mountPoint, options: []) { error in
            if error == nil { removeIfEmpty(mountPoint) }
            completion(error)
        }
    }

    static func removeIfEmpty(_ dir: URL) {
        guard !MountTable.isMounted(dir),
              let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              items.isEmpty else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}

enum MountTable {
    /// Current mount points, read without touching the (possibly dead) network file systems.
    static func mountPoints() -> Set<String> {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        var result = Set<String>()
        for i in 0..<Int(count) {
            var fs = buffer[i]
            let path = withUnsafePointer(to: &fs.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            result.insert(path)
        }
        return result
    }

    static func isMounted(_ url: URL) -> Bool {
        // The mount table keeps the real path (e.g. /private/tmp), URL standardizing may not.
        let mounted = mountPoints()
        return [url.path, url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
            .contains { mounted.contains($0) }
    }
}
