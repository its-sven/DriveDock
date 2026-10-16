import Foundation
import SwiftUI

/// Protocols that can be mounted natively through NetFS.
/// New services (SFTP, S3, ...) need the File Provider variant (phase 2).
enum ServiceKind: String, Codable, CaseIterable, Identifiable {
    case smb
    case webdav
    case webdavs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .smb: "SMB (Windows / NAS)"
        case .webdav: "WebDAV (http)"
        case .webdavs: "WebDAV (https)"
        }
    }

    var scheme: String {
        switch self {
        case .smb: "smb"
        case .webdav: "http"
        case .webdavs: "https"
        }
    }

    var defaultPort: Int {
        switch self {
        case .smb: 445
        case .webdav: 80
        case .webdavs: 443
        }
    }
}

/// Tile color of a server, so profiles of different servers/users are easy to tell apart.
enum ServerColor: String, Codable, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, yellow, green, teal, graphite

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .graphite: .gray
        }
    }

    var label: String {
        switch self {
        case .blue: "Blau"
        case .indigo: "Indigo"
        case .purple: "Lila"
        case .pink: "Pink"
        case .red: "Rot"
        case .orange: "Orange"
        case .yellow: "Gelb"
        case .green: "Grün"
        case .teal: "Türkis"
        case .graphite: "Graphit"
        }
    }
}

/// How a password login reaches the server.
enum AddressMode: String, Codable, CaseIterable, Identifiable {
    case automatic
    /// By IP: Kerberos can't be used, so the server gets exactly the entered user (NTLM).
    case ipAddress
    /// By name: needed when the domain is a Kerberos realm; macOS then fetches a ticket
    /// for the entered user. By IP such servers often never answer.
    case hostname

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatisch"
        case .ipAddress: "IP-Adresse (NTLM)"
        case .hostname: "Servername (Kerberos)"
        }
    }
}

enum AuthMode: String, Codable, CaseIterable, Identifiable {
    /// Always log in with the stored user and password (NTLM), never with the Kerberos ticket.
    case password
    /// Use the domain login (Kerberos ticket) of the Mac; no password needed.
    case kerberos

    var id: String { rawValue }

    var label: String {
        switch self {
        case .password: "Benutzer und Passwort (erzwingen)"
        case .kerberos: "Domänen-Login des Macs (Kerberos)"
        }
    }
}

/// A server profile: one server + one login. Its shares are mounted as subfolders of
/// ~/Netzlaufwerke/<name>, which is a plain folder and keeps the profile's name in Finder.
struct Connection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: ServiceKind = .smb
    /// Primary address, e.g. the LAN hostname.
    var host: String
    /// Fallback addresses tried in order, e.g. an address that only works over VPN.
    var alternateHosts: [String] = []
    var port: Int?
    /// SMB share names (optionally with subfolder) or WebDAV paths.
    var shares: [String]
    var domain: String = ""
    var username: String
    var authMode: AuthMode = .password
    var autoConnect: Bool = true
    /// Mount every share the server offers to this login (like Windows' server view),
    /// except the excluded ones; `shares` is then ignored.
    var mountAllShares = false
    var includeHiddenShares = false
    var excludedShares: [String] = []
    var color: ServerColor = .blue
    var addressMode: AddressMode = .automatic

    init(name: String, kind: ServiceKind = .smb, host: String, shares: [String], username: String) {
        self.name = name
        self.kind = kind
        self.host = host
        self.shares = shares
        self.username = username
    }

    private enum LegacyKeys: String, CodingKey {
        case share
    }

    /// Tolerant decoding so connections saved by older versions keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(ServiceKind.self, forKey: .kind) ?? .smb
        host = try c.decode(String.self, forKey: .host)
        alternateHosts = try c.decodeIfPresent([String].self, forKey: .alternateHosts) ?? []
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        if let shares = try c.decodeIfPresent([String].self, forKey: .shares) {
            self.shares = shares
        } else {
            // Versions up to 0.2 had exactly one share per connection.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            shares = [try legacy.decodeIfPresent(String.self, forKey: .share)].compactMap { $0 }
        }
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        username = try c.decode(String.self, forKey: .username)
        authMode = try c.decodeIfPresent(AuthMode.self, forKey: .authMode) ?? .password
        autoConnect = try c.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? true
        mountAllShares = try c.decodeIfPresent(Bool.self, forKey: .mountAllShares) ?? false
        includeHiddenShares = try c.decodeIfPresent(Bool.self, forKey: .includeHiddenShares) ?? false
        excludedShares = try c.decodeIfPresent([String].self, forKey: .excludedShares) ?? []
        color = try c.decodeIfPresent(ServerColor.self, forKey: .color) ?? .blue
        addressMode = try c.decodeIfPresent(AddressMode.self, forKey: .addressMode) ?? .automatic
    }

    var mountsAll: Bool { kind == .smb && mountAllShares }

    /// Whether a password login should go to the server's IP instead of its name.
    /// A domain with a dot (corp.example) is a Kerberos realm: macOS gets a ticket for the
    /// entered user, which only works with the server name. A short NetBIOS domain (CORP)
    /// can't do that, and by name the Mac's own ticket would take over – so use the IP.
    var connectsByIP: Bool {
        guard kind == .smb, authMode == .password else { return false }
        switch addressMode {
        case .ipAddress: return true
        case .hostname: return false
        case .automatic: return !domain.contains(".")
        }
    }

    /// Kerberos only exists for SMB; everything else always needs a password.
    var needsPassword: Bool { kind != .smb || authMode == .password }

    static func blank() -> Connection {
        Connection(name: "Neuer Server", host: "", shares: [], username: "")
    }

    /// Copy with a new identity, e.g. to add a second user on the same server.
    func duplicate() -> Connection {
        var copy = self
        copy.id = UUID()
        copy.name = "\(name) Kopie"
        return copy
    }

    var effectivePort: Int { port ?? kind.defaultPort }

    var allHosts: [String] {
        ([host] + alternateHosts)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var displayUser: String {
        if !needsPassword { return "Domänen-Login" }
        return domain.isEmpty ? username : "\(domain)\\\(username)"
    }

    var summary: String { "\(displayUser) @ \(host)" }

    /// Folder name of the profile below the mount root; unique per connection.
    var mountFolderName: String {
        let cleaned = Self.folderName(name)
        return cleaned.isEmpty ? id.uuidString : cleaned
    }

    static func folderName(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            .replacingOccurrences(of: "/", with: " - ")
            .replacingOccurrences(of: ":", with: "-")
    }

    static func normalizedShare(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "/\\ "))
    }
}

enum ConnectionStatus: Equatable {
    case disconnected
    case paused
    case connecting
    case connected
    /// Some shares mounted, others failed (e.g. one share no longer exists).
    case partial(mounted: Int, total: Int, detail: String)
    case unreachable
    case needsPassword
    case authFailed
    case error(String)

    var label: String {
        switch self {
        case .disconnected: "Nicht verbunden"
        case .paused: "Getrennt (manuell)"
        case .connecting: "Verbinde …"
        case .connected: "Verbunden"
        case .partial(let mounted, let total, let detail): "\(mounted) von \(total) Freigaben verbunden – \(detail)"
        case .unreachable: "Server nicht erreichbar – versuche es weiter"
        case .needsPassword: "Kein Passwort hinterlegt"
        case .authFailed: "Anmeldung fehlgeschlagen – bitte Zugangsdaten prüfen"
        case .error(let message): message
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .connecting: .yellow
        case .unreachable, .partial: .orange
        case .disconnected, .paused: .gray
        case .needsPassword, .authFailed, .error: .red
        }
    }

    var isProblem: Bool {
        switch self {
        case .needsPassword, .authFailed, .error: true
        default: false
        }
    }
}
