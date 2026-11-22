import Foundation
import Testing
@testable import DriveDock

// MARK: - Share list (smbutil view)

@Suite("Share list parsing")
struct ShareListTests {
    /// smbutil pads the share column to 48 bytes, like printf("%-48s").
    static func line(_ name: String, _ type: String, _ comment: String = "") -> String {
        let padding = max(1, 48 - name.utf8.count)
        return name + String(repeating: " ", count: padding) + type.padding(toLength: 8, withPad: " ", startingAt: 0) + comment
    }

    static let listing = ([
        "Share                                           Type    Comments",
        "-------------------------------",
        line("EDV", "Disk", "IT department"),
        line("USB Disk", "Disk"),
        line("Backup Device", "Disk", "Nightly backups"),
        line("Share", "Disk", "Common share"),
        line("Zusatztätigkeiten", "Disk"),
        line("EMAS – 14001", "Disk", "Passwords: see vault"),
        line("Printer HP", "Printer"),
        line("IPC$", "Pipe", "Remote IPC"),
        "A_really_long_share_name_that_exceeds_the_column_width Disk    overflow",
        line("C$", "Disk", "Default share"),
    ]).joined(separator: "\n")

    @Test func namesWithSpacesUmlautsAndTypeWords() {
        let names = ShareBrowser.parse(Self.listing).map(\.name)
        #expect(names.contains("USB Disk"))
        #expect(names.contains("Backup Device"))
        #expect(names.contains("Share"))
        #expect(names.contains("Zusatztätigkeiten"))
        #expect(names.contains("EMAS – 14001"))
        #expect(names.contains("A_really_long_share_name_that_exceeds_the_column_width"))
    }

    @Test func onlyDisksAndHiddenLast() {
        let shares = ShareBrowser.parse(Self.listing)
        #expect(!shares.map(\.name).contains("Printer HP"))
        #expect(!shares.map(\.name).contains("IPC$"))
        #expect(shares.last?.name == "C$")
        #expect(shares.last?.isHidden == true)
    }

    @Test func comments() {
        let shares = ShareBrowser.parse(Self.listing)
        #expect(shares.first { $0.name == "EDV" }?.comment == "IT department")
        #expect(shares.first { $0.name == "EMAS – 14001" }?.comment == "Passwords: see vault")
    }

    @Test func noHeaderNoShares() {
        #expect(ShareBrowser.parse("smbutil: server rejected the connection: Authentication error").isEmpty)
    }
}

// MARK: - Model

@Suite("Connection model")
struct ConnectionTests {
    @Test func folderNamesStayInsideTheMountRoot() {
        #expect(Connection.folderName("..") == "")
        #expect(Connection.folderName(".hidden") == "hidden")
        #expect(Connection.folderName("A/B") == "A - B")
        #expect(Connection.folderName("A:B") == "A-B")
        #expect(Connection.folderName("  /Data/  ") == "Data")
    }

    @Test func emptyNameFallsBackToID() {
        let c = Connection(name: "..", host: "h", shares: [], username: "u")
        #expect(c.mountFolderName == c.id.uuidString)
    }

    @Test func decodesFilesFromOlderVersions() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"Old","host":"srv","share":"Data","username":"anna"}]"#
        let decoded = try JSONDecoder().decode([Connection].self, from: Data(json.utf8))
        #expect(decoded[0].shares == ["Data"])
        #expect(decoded[0].authMode == .password)
        #expect(decoded[0].autoConnect)
        #expect(decoded[0].color == .blue)
    }

    @Test func roundTrip() throws {
        var c = Connection(name: "NAS", kind: .webdavs, host: "cloud.example.com", shares: ["remote.php/dav"], username: "anna")
        c.alternateHosts = ["10.0.0.2"]
        c.excludedShares = ["X"]
        let back = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }

    @Test func connectsByIPOnlyForShortDomainsWithPassword() {
        var c = Connection(name: "S", host: "fileserver", shares: ["A"], username: "anna")
        c.domain = "CORP"
        #expect(c.connectsByIP)
        c.domain = "corp.example.com"
        #expect(!c.connectsByIP)
        c.addressMode = .ipAddress
        #expect(c.connectsByIP)
        c.authMode = .kerberos
        #expect(!c.connectsByIP)
        c.kind = .webdavs
        #expect(!c.connectsByIP)
    }
}

// MARK: - URLs

@Suite("SMB URLs")
struct URLTests {
    @Test func domainUserAndEncodedShare() {
        var c = Connection(name: "S", host: "fileserver", shares: [], username: "an na@x")
        c.domain = "corp.example.com"   // by name
        #expect(Mounter.smbURL(for: c, host: "fileserver", share: "Projekte 2026/Zusatztätigkeiten")
                == "//corp.example.com;an%20na%40x@fileserver/Projekte%202026/Zusatzt%C3%A4tigkeiten")
    }

    @Test func shortDomainResolvesToIP() {
        var c = Connection(name: "S", host: "localhost", shares: [], username: "anna")
        c.domain = "CORP"
        #expect(Mounter.smbURL(for: c, host: "localhost", share: "EDV") == "//CORP;anna@127.0.0.1/EDV")
    }

    @Test func ipv6AndPort() {
        var c = Connection(name: "S", host: "fe80::1", shares: [], username: "anna")
        c.addressMode = .hostname
        c.port = 4450
        #expect(Mounter.smbURL(for: c, host: "fe80::1", share: "A") == "//anna@[fe80::1]:4450/A")
    }

    @Test func kerberosHasNoUser() {
        var c = Connection(name: "S", host: "fileserver.corp.example.com", shares: [], username: "anna")
        c.authMode = .kerberos
        #expect(Mounter.smbURL(for: c, host: c.host, share: nil) == "//fileserver.corp.example.com")
    }
}

// MARK: - Mount table

@Suite("Mount table")
struct MountTableTests {
    @Test func containsTheRootVolume() {
        #expect(MountTable.mountPoints().contains("/"))
    }

    @Test func pathComparisonWithoutFileSystemAccess() {
        let mounted: Set<String> = ["/Users/x/Network Drives/Server/Data", "/private/tmp/m"]
        #expect(MountTable.isMounted(URL(fileURLWithPath: "/Users/x/Network Drives/Server/Data"), in: mounted))
        #expect(MountTable.isMounted(URL(fileURLWithPath: "/tmp/m"), in: mounted))
        #expect(!MountTable.isMounted(URL(fileURLWithPath: "/Users/x/Network Drives/Server"), in: mounted))
    }

    /// getmntinfo() crashed when read from several threads while mounts changed (0.5.0).
    @Test func readingFromManyThreadsAtOnce() {
        let expected = MountTable.mountPoints()
        let mismatches = LockedValue(0)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            for _ in 0..<500 where !MountTable.mountPoints().isSuperset(of: ["/"]) {
                mismatches.modify { $0 += 1 }
            }
        }
        #expect(mismatches.get() == 0)
        #expect(!expected.isEmpty)
    }
}

// MARK: - Command line tools

@Suite("ToolRunner")
struct ToolRunnerTests {
    @Test func output() {
        let r = ToolRunner.run("/bin/echo", ["hello"], timeout: 5)
        #expect(r.status == 0)
        #expect(r.output == "hello\n")
    }

    @Test func hardTimeout() {
        let start = Date()
        let r = ToolRunner.run("/bin/sleep", ["30"], timeout: 1)
        #expect(r.timedOut)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func childKeepingThePipeOpenDoesNotHang() {
        let start = Date()
        let r = ToolRunner.run("/bin/sh", ["-c", "sleep 30 & echo hi"], timeout: 10)
        #expect(r.output == "hi\n")
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func largeOutput() {
        let r = ToolRunner.run("/bin/sh", ["-c", "head -c 1000000 /dev/zero | tr '\\\\0' a"], timeout: 10)
        #expect(r.output.count == 1_000_000)
    }

    @Test func answersThePasswordPromptOnce() {
        let script = "printf 'Password for srv: '; read pw; echo \"got $pw\"; echo 'Passwords: comment'"
        let r = ToolRunner.runWithPassword("/bin/sh", ["-c", script], password: "secret", timeout: 10)
        #expect(r.status == 0)
        #expect(!r.passwordRejected)
        #expect(r.output.contains("got secret"))
    }

    /// A share list longer than expect's default buffer (2000 bytes) must arrive complete.
    @Test func longOutputAfterThePasswordIsComplete() {
        let script = "printf 'Password for srv: '; read pw; echo 'Share  Type'; "
            + "i=0; while [ $i -lt 200 ]; do echo \"Share$i                                 Disk\"; i=$((i+1)); done; echo END"
        let r = ToolRunner.runWithPassword("/bin/sh", ["-c", script], password: "secret", timeout: 10)
        #expect(r.status == 0)
        #expect(r.output.contains("Share  Type"))
        #expect(r.output.contains("Share0 "))
        #expect(r.output.hasSuffix("END\n"))
    }

    @Test func secondPromptMeansRejected() {
        let script = "printf 'Password: '; read a; printf 'Password: '; read b"
        let r = ToolRunner.runWithPassword("/bin/sh", ["-c", script], password: "wrong", timeout: 10)
        #expect(r.passwordRejected)
    }
}

// MARK: - Store

@Suite("Connection store")
struct StoreTests {
    @Test func unreadableEntriesDontLoseTheOthers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drivedock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("connections.json")
        let json = #"""
        [{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"Good","host":"srv","shares":["A"],"username":"u"},
         {"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FE","name":"Future","host":"srv","shares":["A"],"username":"u","kind":"sftp"}]
        """#
        try Data(json.utf8).write(to: file)

        let loaded = ConnectionStore(fileURL: file).load()
        #expect(loaded.map(\.name) == ["Good"])
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("connections-") }
        #expect(backups.count == 1)
    }
}
