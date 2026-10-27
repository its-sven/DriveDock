import AppKit
import Foundation
import Network

/// Keeps every auto-connect share mounted: retries periodically and right after
/// wake, network changes (Wi-Fi/VPN) and unmounts.
@MainActor
final class ConnectionManager: ObservableObject {
    /// Folder that holds one subfolder per server profile. Its name follows the system
    /// language on first launch ("Network Drives", German "Netzlaufwerke") and is then kept,
    /// so mounts and Finder favorites don't move when the language changes.
    nonisolated static let mountRoot: URL = {
        let key = "mountRootName"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: key) {
            return home.appendingPathComponent(name, isDirectory: true)
        }
        // Installations before 0.5 always used the German name.
        let legacy = "Netzlaufwerke"
        let name: String
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(legacy).path) {
            name = legacy
        } else {
            name = Bundle.main.preferredLocalizations.first == "de" ? legacy : "Network Drives"
        }
        defaults.set(name, forKey: key)
        return home.appendingPathComponent(name, isDirectory: true)
    }()

    private static let retryInterval: TimeInterval = 20
    /// How often "all shares" profiles look for shares that were added or removed on the server.
    private static let rediscoveryInterval: TimeInterval = 15 * 60
    /// Mounts per profile that run at the same time.
    private static let parallelMounts = 4

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var status: [UUID: ConnectionStatus] = [:]
    /// Shares the server offered at the last discovery.
    @Published private(set) var discovered: [UUID: [ShareBrowser.Share]] = [:]
    /// Shares the login may see but not open (Windows lists those too); not retried until the next discovery.
    @Published private(set) var denied: [UUID: Set<String>] = [:]
    /// Snapshot of the mount table for the UI, refreshed after every change we make and on
    /// every reconcile – views must not query the system on each render.
    @Published private(set) var mountedPaths: Set<String> = []

    private var discoveredAt: [UUID: Date] = [:]
    /// Disconnected via the app; stays disconnected until connected again or the app restarts.
    private var paused: Set<UUID> = []
    /// Wrong credentials: no automatic retries, so Windows/AD accounts don't get locked out.
    private var authBlocked: Set<UUID> = []
    private var inFlight: Set<UUID> = []
    /// A connect was requested while another one was running; run it when that one ends.
    private var pendingConnect: Set<UUID> = []
    /// Bumped by disconnect, save and delete. A connect attempt that finds a newer
    /// generation after one of its waits is outdated and takes back what it mounted.
    private var generation: [UUID: Int] = [:]
    private var unmounting: Set<String> = []

    private let store = ConnectionStore()
    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        connections = store.load()
        start()
    }

    // MARK: - Lifecycle

    private func start() {
        try? FileManager.default.createDirectory(at: Self.mountRoot, withIntermediateDirectories: true)
        FinderSidebar.addOnFirstLaunch(Self.mountRoot)

        timer = Timer.scheduledTimer(withTimeInterval: Self.retryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.reconcile(after: 2) }
        }
        pathMonitor.start(queue: .global(qos: .utility))

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reconcile(after: 3) }
            })
        }

        migrateLegacyMounts { [weak self] in
            guard let self else { return }
            FinderSidebar.migrateToProfileFolders(root: Self.mountRoot)
            connections.forEach { self.prepareFinderEntry($0, addToSidebar: true) }
            reconcile()
        }
    }

    func reconcile(after delay: TimeInterval) {
        Task {
            try? await Task.sleep(for: .seconds(delay))
            reconcile()
        }
    }

    /// Compares the desired state with the mount table and connects what is missing.
    func reconcile() {
        let mounted = refreshMountTable()
        for c in connections where !inFlight.contains(c.id) {
            if paused.contains(c.id) {
                // Keep a disconnected profile disconnected, also against mounts that finished late.
                let leftovers = mountsInside(c, mounted: mounted)
                if !leftovers.isEmpty { unmount(leftovers) }
                setStatus(.paused, for: c.id)
                continue
            }
            pruneMounts(of: c, mounted: mounted)
            let wanted = targets(of: c)
            let mountedCount = wanted.filter { MountTable.isMounted(mountPoint(for: c, share: $0), in: mounted) }.count
            let fresh = !needsDiscovery(c)

            if fresh, !wanted.isEmpty, mountedCount == wanted.count {
                setStatus(.connected, for: c.id)
                continue
            }
            if authBlocked.contains(c.id) { continue }
            if c.mountsAll, fresh, wanted.isEmpty {
                setStatus(.error(tr("No accessible shares found")), for: c.id)
                continue
            }
            guard c.autoConnect else {
                if mountedCount > 0 {
                    setStatus(.partial(mounted: mountedCount, total: wanted.count, detail: tr("the rest is not connected")), for: c.id)
                } else if case .error = status(of: c) {
                    // keep the last error visible
                } else {
                    setStatus(.disconnected, for: c.id)
                }
                continue
            }
            if !wanted.isEmpty || c.mountsAll { connect(c, manual: false) }
        }
    }

    /// Publishes only real changes: every assignment to a @Published property re-renders
    /// all open views, and the reconcile timer would otherwise do that every 20 seconds.
    private func setStatus(_ new: ConnectionStatus?, for id: UUID) {
        guard status[id] != new else { return }
        status[id] = new
        if let new {
            let name = connections.first { $0.id == id }?.name ?? id.uuidString
            ActivityLog.write("\(name): \(new.label)")
        }
    }

    @discardableResult
    private func refreshMountTable() -> Set<String> {
        let current = MountTable.mountPoints()
        if current != mountedPaths { mountedPaths = current }
        return current
    }

    // MARK: - Shares

    /// Shares the profile should have mounted, before permission problems.
    func activeShares(of c: Connection) -> [String] {
        guard c.mountsAll else { return c.shares }
        return (discovered[c.id] ?? [])
            .filter { c.includeHiddenShares || !$0.isHidden }
            .map(\.name)
            .filter { !c.excludedShares.contains($0) }
    }

    private func targets(of c: Connection) -> [String] {
        let deniedShares = denied[c.id] ?? []
        return activeShares(of: c).filter { !deniedShares.contains($0) }
    }

    private func needsDiscovery(_ c: Connection) -> Bool {
        guard c.mountsAll else { return false }
        guard let last = discoveredAt[c.id] else { return true }
        return Date().timeIntervalSince(last) > Self.rediscoveryInterval
    }

    /// For the UI: answers from the cached mount table.
    func isMounted(_ c: Connection, share: String) -> Bool {
        MountTable.isMounted(mountPoint(for: c, share: share), in: mountedPaths)
    }

    func isDenied(_ c: Connection, share: String) -> Bool {
        denied[c.id]?.contains(share) ?? false
    }

    /// All mount points below the profile folder, whatever share they belong to.
    private func mountsInside(_ c: Connection, mounted: Set<String>) -> [URL] {
        let prefix = profileFolder(for: c).path + "/"
        return mounted.filter { $0.hasPrefix(prefix) }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Unmounts shares that were deselected, excluded or removed on the server.
    private func pruneMounts(of c: Connection, mounted: Set<String>) {
        // Without a discovery the wanted list of an "all shares" profile is still unknown.
        if c.mountsAll, discovered[c.id] == nil { return }
        let wanted = Set(targets(of: c).map { mountPoint(for: c, share: $0).path })
        let stale = mountsInside(c, mounted: mounted).filter { !wanted.contains($0.path) }
        if !stale.isEmpty { unmount(stale) }
    }

    // MARK: - Paths

    /// The profile's folder, e.g. ~/Network Drives/Fileserver (Admin). A plain folder, so Finder
    /// shows the profile name; the shares inside are mount points.
    func profileFolder(for c: Connection) -> URL {
        Self.mountRoot.appendingPathComponent(c.mountFolderName, isDirectory: true).standardizedFileURL
    }

    func mountPoint(for c: Connection, share: String) -> URL {
        let name = Connection.folderName(Connection.normalizedShare(share))
        return profileFolder(for: c).appendingPathComponent(name.isEmpty ? "Share" : name, isDirectory: true)
    }

    private func prepareFinderEntry(_ c: Connection, addToSidebar: Bool = false) {
        let folder = profileFolder(for: c)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent("Icon\r").path),
           let icon = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericFileServerIcon.icns") {
            NSWorkspace.shared.setIcon(icon, forFile: folder.path)
        }
        if addToSidebar { FinderSidebar.addOnce(folder, for: c.id) }
    }

    /// Removes the profile's (empty) folders and its sidebar entry. rmdir() only, so nothing
    /// that is still mounted or has content can be deleted.
    private func removeFinderEntry(_ c: Connection) {
        let folder = profileFolder(for: c)
        FinderSidebar.remove(folder)
        FinderSidebar.forget(c.id)
        if let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            items.forEach(Mounter.removeIfEmpty)
        }
        unlink(folder.appendingPathComponent("Icon\r").path)
        Mounter.removeIfEmpty(folder)
    }

    /// Up to 0.2 the share was mounted directly on the profile folder; move such mounts.
    /// Runs once at launch – a failure leaves the profile in an error state instead of retrying.
    private func migrateLegacyMounts(then: @escaping () -> Void) {
        let legacy = connections.map { profileFolder(for: $0) }.filter { MountTable.isMounted($0) }
        unmountAll(legacy) { _ in then() }
    }

    // MARK: - Actions

    func status(of c: Connection) -> ConnectionStatus {
        status[c.id] ?? .disconnected
    }

    func isKeptConnected(_ c: Connection) -> Bool {
        !paused.contains(c.id) && (c.autoConnect || status(of: c) == .connected)
    }

    private func bumpGeneration(_ id: UUID) {
        generation[id, default: 0] += 1
    }

    func connect(_ c: Connection, manual: Bool = true) {
        guard connections.contains(where: { $0.id == c.id }) else { return }
        if manual {
            paused.remove(c.id)
            authBlocked.remove(c.id)
        }
        guard !inFlight.contains(c.id) else {
            // Don't drop it: run it as soon as the current attempt ends.
            if manual { pendingConnect.insert(c.id) }
            return
        }
        // Never create share folders while something is mounted on the profile folder
        // itself (old layout or a manual mount): they would end up on that server.
        if MountTable.isMounted(profileFolder(for: c)) {
            setStatus(.error(tr("The folder “%@” is itself a network drive – please disconnect it", c.mountFolderName)), for: c.id)
            return
        }

        inFlight.insert(c.id)
        let attempt = generation[c.id, default: 0]
        // While waiting for an unreachable server, keep showing that instead of flickering.
        if manual || status[c.id] != .unreachable { setStatus(.connecting, for: c.id) }
        prepareFinderEntry(c)

        Task { @MainActor in
            // Off the main thread: the keychain may show an access prompt and block.
            let password = await Blocking.run { Keychain.password(for: c.id) }
            guard isCurrent(c.id, attempt: attempt) else { return finishConnect(c, attempt: attempt, mounted: []) }
            if c.needsPassword, password == nil {
                setStatus(.needsPassword, for: c.id)
                return finishConnect(c, attempt: attempt, mounted: [])
            }
            guard let host = await Reachability.firstReachable(hosts: c.allHosts, port: c.effectivePort) else {
                if isCurrent(c.id, attempt: attempt) { setStatus(.unreachable, for: c.id) }
                return finishConnect(c, attempt: attempt, mounted: [])
            }
            guard isCurrent(c.id, attempt: attempt) else { return finishConnect(c, attempt: attempt, mounted: []) }

            // Listing the shares is also a single login check. If it works, a share that later
            // refuses access is a permission problem and not a wrong password – no lockout risk.
            // Always for SMB: macOS falls back to guest access when a mount's login fails, so a
            // wrong password would go unnoticed on servers that allow guests. smbutil doesn't.
            var loginVerified = false
            if c.kind == .smb {
                do {
                    let shares = try await Blocking.run { try ShareBrowser.list(c, host: host, password: password) }
                    guard isCurrent(c.id, attempt: attempt) else { return finishConnect(c, attempt: attempt, mounted: []) }
                    if discovered[c.id] != shares { discovered[c.id] = shares }
                    discoveredAt[c.id] = Date()
                    if denied[c.id]?.isEmpty == false { denied[c.id] = [] }
                    loginVerified = true
                } catch let error as ShareBrowser.BrowseError where error.isAuthFailure {
                    guard isCurrent(c.id, attempt: attempt) else { return finishConnect(c, attempt: attempt, mounted: []) }
                    authBlocked.insert(c.id)
                    setStatus(.authFailed, for: c.id)
                    return finishConnect(c, attempt: attempt, mounted: [])
                } catch {
                    guard isCurrent(c.id, attempt: attempt) else { return finishConnect(c, attempt: attempt, mounted: []) }
                    if c.mountsAll, discovered[c.id] == nil {
                        setStatus(.error(tr("Could not load the shares: %@", error.localizedDescription)), for: c.id)
                        return finishConnect(c, attempt: attempt, mounted: [])
                    }
                }
            }

            let wanted = targets(of: c)
            if wanted.isEmpty {
                setStatus(c.mountsAll ? .error(tr("No accessible shares found")) : .disconnected, for: c.id)
                return finishConnect(c, attempt: attempt, mounted: [])
            }
            let alreadyMounted = MountTable.mountPoints()
            let todo = wanted
                .map { ($0, mountPoint(for: c, share: $0)) }
                .filter { !MountTable.isMounted($0.1, in: alreadyMounted) }

            let results = await Self.mount(todo, of: c, host: host, password: password,
                                           parallel: c.kind == .smb ? Self.parallelMounts : 1)
            let mountedByThisAttempt = results.filter { $0.error == nil }.map { mountPoint(for: c, share: $0.share) }
            guard isCurrent(c.id, attempt: attempt) else { return finishConnect(c, attempt: attempt, mounted: mountedByThisAttempt) }

            for result in results {
                if let error = result.error as? MountError {
                    ActivityLog.write("  \(c.name) / \(result.share): error \(error.code) – \(error.localizedDescription)")
                } else if let error = result.error {
                    ActivityLog.write("  \(c.name) / \(result.share): \(error.localizedDescription)")
                }
            }

            let authFailures = results.filter { ($0.error as? MountError)?.isAuthFailure == true }.map(\.share)
            // Windows answers "not found" instead of "access denied" for e.g. C$ when the user
            // lacks rights; a share the server just listed does exist, so that means no access.
            let listed = Set((discovered[c.id] ?? []).map(\.name))
            let nowMounted = MountTable.mountPoints()
            let mountedNow = wanted.filter { MountTable.isMounted(mountPoint(for: c, share: $0), in: nowMounted) }
            // Same for shares that never answer while other shares of the same login do mount
            // (a successful listing is not enough: then the whole server may be the problem).
            let hiddenFromUser = results
                .filter { result in
                    guard let code = (result.error as? MountError)?.code, listed.contains(result.share) else { return false }
                    return code == ENOENT || (code == ETIMEDOUT && !mountedNow.isEmpty)
                }
                .map(\.share)
            if !authFailures.isEmpty {
                if loginVerified || !mountedNow.isEmpty {
                    denied[c.id, default: []].formUnion(authFailures)
                } else {
                    authBlocked.insert(c.id)
                    setStatus(.authFailed, for: c.id)
                    return finishConnect(c, attempt: attempt, mounted: [])
                }
            }
            if !hiddenFromUser.isEmpty { denied[c.id, default: []].formUnion(hiddenFromUser) }
            let noAccess = Set(authFailures + hiddenFromUser)
            let failures = results.compactMap { result -> String? in
                guard let error = result.error, !noAccess.contains(result.share) else { return nil }
                return "\(result.share): \(error.localizedDescription)"
            }

            let total = targets(of: c).count
            if total == 0, !results.isEmpty {
                let names = (denied[c.id] ?? []).sorted().joined(separator: ", ")
                setStatus(.error(failures.isEmpty
                    ? tr("No access to %@ – the login works, but the server refuses these shares", names)
                    : failures.joined(separator: "; ")), for: c.id)
            } else if mountedNow.count == total {
                setStatus(.connected, for: c.id)
            } else if !mountedNow.isEmpty {
                setStatus(.partial(mounted: mountedNow.count, total: total, detail: failures.joined(separator: "; ")), for: c.id)
            } else {
                setStatus(.error(failures.isEmpty ? tr("No share connected") : failures.joined(separator: "; ")), for: c.id)
            }
            finishConnect(c, attempt: attempt, mounted: [])
        }
    }

    /// Still the attempt the user wants: not disconnected, edited or deleted meanwhile.
    private func isCurrent(_ id: UUID, attempt: Int) -> Bool {
        generation[id, default: 0] == attempt && !paused.contains(id) && connections.contains { $0.id == id }
    }

    /// Ends a connect attempt. An outdated one first takes back what it mounted; then a
    /// connect that was requested meanwhile (or the one for the new settings) runs.
    private func finishConnect(_ c: Connection, attempt: Int, mounted: [URL]) {
        let outdated = !isCurrent(c.id, attempt: attempt)
        let done = { [weak self] in
            guard let self else { return }
            inFlight.remove(c.id)
            refreshMountTable()
            if outdated, !connections.contains(where: { $0.id == c.id }) {
                removeFinderEntry(c)
            }
            if pendingConnect.remove(c.id) != nil || outdated,
               let current = connections.first(where: { $0.id == c.id }), !paused.contains(c.id) {
                connect(current, manual: false)
            }
        }
        if outdated, !mounted.isEmpty {
            unmount(mounted) { _ in done() }
        } else {
            done()
        }
    }

    /// Mounts with limited parallelism. The blocking work runs on the Blocking queue, so the
    /// child tasks only wait and never hold a thread of the cooperative pool.
    nonisolated private static func mount(
        _ todo: [(String, URL)], of c: Connection, host: String, password: String?, parallel: Int
    ) async -> [(share: String, error: Error?)] {
        await withTaskGroup(of: (share: String, error: Error?).self) { group in
            var pending = todo[...]
            var results: [(share: String, error: Error?)] = []
            func addNext() {
                guard let (share, url) = pending.popFirst() else { return }
                group.addTask {
                    do {
                        try await Blocking.run { try Mounter.mount(c, share: share, host: host, password: password, at: url) }
                        return (share, nil)
                    } catch {
                        return (share, error)
                    }
                }
            }
            for _ in 0..<parallel { addNext() }
            while let result = await group.next() {
                results.append(result)
                addNext()
            }
            return results
        }
    }

    func disconnect(_ c: Connection, then: (() -> Void)? = nil) {
        paused.insert(c.id)
        pendingConnect.remove(c.id)
        bumpGeneration(c.id)
        let mounted = mountsInside(c, mounted: MountTable.mountPoints())
        unmount(mounted) { [weak self] errors in
            guard let self else { return }
            // The user may have reconnected meanwhile – then that attempt owns the status.
            if paused.contains(c.id) {
                if let error = errors.first {
                    setStatus(.error(tr("Disconnecting failed: %@", error.localizedDescription)), for: c.id)
                } else {
                    setStatus(.paused, for: c.id)
                }
            }
            then?()
        }
    }

    /// Unmounts `urls` (skipping those already being unmounted) and reports on the main actor.
    private func unmount(_ urls: [URL], completion: (([Error]) -> Void)? = nil) {
        let fresh = urls.filter { !unmounting.contains($0.path) }
        fresh.forEach { unmounting.insert($0.path) }
        unmountAll(fresh) { [weak self] errors in
            guard let self else { return }
            fresh.forEach { self.unmounting.remove($0.path) }
            refreshMountTable()
            completion?(errors)
        }
    }

    /// Unmounts one after another and reports all errors on the main actor.
    private func unmountAll(_ urls: [URL], completion: @escaping ([Error]) -> Void) {
        var remaining = urls
        var errors: [Error] = []
        func next() {
            guard let url = remaining.popLast() else {
                completion(errors)
                return
            }
            Mounter.unmount(at: url) { error in
                Task { @MainActor in
                    if let error { errors.append(error) }
                    next()
                }
            }
        }
        next()
    }

    func connectAll() {
        connections.forEach { connect($0) }
    }

    func openInFinder(_ c: Connection, share: String? = nil) {
        prepareFinderEntry(c)
        NSWorkspace.shared.open(share.map { mountPoint(for: c, share: $0) } ?? profileFolder(for: c))
    }

    // MARK: - Editing

    /// Adds or updates a profile. A non-empty password replaces the stored one.
    func save(_ connection: Connection, password: String?) {
        var c = connection
        c.name = uniqueName(c.name.trimmingCharacters(in: .whitespaces), excluding: c.id)
        c.shares = c.shares.map(Connection.normalizedShare).filter { !$0.isEmpty }
        if let password, !password.isEmpty {
            Keychain.setPassword(password, for: c.id, label: c.name)
        }
        authBlocked.remove(c.id)
        paused.remove(c.id)
        setStatus(nil, for: c.id)

        guard let index = connections.firstIndex(where: { $0.id == c.id }) else {
            connections.append(c)
            store.save(connections)
            prepareFinderEntry(c, addToSidebar: true)
            if c.autoConnect { connect(c) } else { reconcile() }
            return
        }

        let old = connections[index]
        connections[index] = c
        store.save(connections)

        // Share selection alone can be applied live; anything about server or login needs a remount.
        var comparable = old
        comparable.shares = c.shares
        comparable.mountAllShares = c.mountAllShares
        comparable.includeHiddenShares = c.includeHiddenShares
        comparable.excludedShares = c.excludedShares
        comparable.autoConnect = c.autoConnect
        comparable.color = c.color
        let loginChanged = comparable != c || password?.isEmpty == false

        guard loginChanged else {
            pruneMounts(of: c, mounted: MountTable.mountPoints())
            if c.autoConnect { connect(c) } else { reconcile() }
            return
        }

        // A connect still running with the old settings is now outdated.
        bumpGeneration(c.id)
        discovered[c.id] = nil
        discoveredAt[c.id] = nil
        denied[c.id] = nil
        unmount(mountsInside(old, mounted: MountTable.mountPoints())) { [weak self] _ in
            guard let self else { return }
            if old.mountFolderName != c.mountFolderName {
                removeFinderEntry(old)
                prepareFinderEntry(c, addToSidebar: true)
            }
            if c.autoConnect { connect(c) } else { reconcile() }
        }
    }

    func delete(_ c: Connection) {
        disconnect(c) { [weak self] in
            guard let self else { return }
            Keychain.delete(for: c.id)
            connections.removeAll { $0.id == c.id }
            removeFinderEntry(c)
            setStatus(nil, for: c.id)
            discovered[c.id] = nil
            discoveredAt[c.id] = nil
            denied[c.id] = nil
            paused.remove(c.id)
            authBlocked.remove(c.id)
            pendingConnect.remove(c.id)
            generation[c.id] = nil
            store.save(connections)
        }
    }

    /// Unique by folder name, not just by display name: "A/B" and "A - B" would share a folder,
    /// and the two profiles would then unmount each other's shares forever.
    private func uniqueName(_ name: String, excluding id: UUID) -> String {
        let base = name.isEmpty ? "Server" : name
        let taken = Set(connections.filter { $0.id != id }.map { $0.mountFolderName.lowercased() })
        var candidate = base
        var n = 2
        while taken.contains(Connection.folderName(candidate).lowercased()) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    // MARK: - Overview

    var mountedShareCount: Int {
        connections.reduce(0) { $0 + mountsInside($1, mounted: mountedPaths).count }
    }

    var menuBarSymbol: String {
        let states = connections.map { status(of: $0) }
        if states.contains(where: \.isProblem) { return "externaldrive.badge.exclamationmark" }
        if !states.isEmpty, states.allSatisfy({ $0 == .connected }) { return "externaldrive.badge.checkmark" }
        return "externaldrive.connected.to.line.below"
    }
}
