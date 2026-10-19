import AppKit
import SwiftUI

// Note: plain @State is a macro in current SDKs and needs Xcode's SwiftUIMacros plugin,
// which the Command Line Tools don't ship. View state therefore lives in small ObservableObjects.

private enum SidebarItem: Hashable {
    case server(UUID)
    case new(UUID)
    case general
}

private final class SettingsState: ObservableObject {
    @Published var selection: SidebarItem?
    @Published var draft: Connection?
    /// Password carried over when duplicating a server.
    @Published var draftPassword = ""
    @Published var confirmDelete: Connection?
}

struct SettingsView: View {
    @EnvironmentObject private var manager: ConnectionManager
    @StateObject private var state = SettingsState()

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selection) {
                Section("Server") {
                    ForEach(manager.connections) { c in
                        ServerSidebarRow(connection: c)
                            .tag(SidebarItem.server(c.id))
                            .contextMenu { contextMenu(for: c) }
                    }
                    if let draft = state.draft {
                        HStack(spacing: 10) {
                            IconTile(symbol: "plus", color: draft.color.color, size: 26)
                            Text(draft.name.isEmpty ? tr("New Server") : draft.name)
                        }
                        .tag(SidebarItem.new(draft.id))
                    }
                }
                Section {
                    HStack(spacing: 10) {
                        IconTile(symbol: "gearshape.fill", color: .gray, size: 26)
                        Text("General")
                    }
                    .tag(SidebarItem.general)
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 250)
            .toolbar {
                ToolbarItem {
                    Button {
                        addServer()
                    } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                    .help("Add Server")
                }
            }
        } detail: {
            detail
        }
        .onChange(of: state.selection) { _, new in
            if case .new = new { return }
            state.draft = nil
        }
        .onAppear {
            guard state.selection == nil else { return }
            if let first = manager.connections.first {
                state.selection = .server(first.id)
            } else {
                addServer()
            }
        }
        .confirmationDialog(
            tr("Remove “%@”?", state.confirmDelete?.name ?? ""),
            isPresented: Binding(get: { state.confirmDelete != nil }, set: { if !$0 { state.confirmDelete = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let c = state.confirmDelete {
                    manager.delete(c)
                    state.selection = manager.connections.first { $0.id != c.id }.map { .server($0.id) } ?? .general
                }
                state.confirmDelete = nil
            }
        } message: {
            Text("All shares are disconnected, the Finder sidebar entry is removed and the password is deleted from the keychain.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.selection {
        case .server(let id):
            if let c = manager.connections.first(where: { $0.id == id }) {
                ServerEditor(original: c, isNew: false,
                             onSaved: { state.selection = .server($0) },
                             onDelete: { state.confirmDelete = c },
                             onDuplicate: { duplicate(c) })
                    .id(c)
            } else {
                placeholder
            }
        case .new:
            if let draft = state.draft {
                ServerEditor(original: draft, isNew: true, initialPassword: state.draftPassword,
                             onSaved: { id in
                                 state.draft = nil
                                 state.selection = .server(id)
                             },
                             onDelete: {
                                 state.draft = nil
                                 state.selection = manager.connections.first.map { .server($0.id) } ?? .general
                             })
                    .id(draft.id)
            } else {
                placeholder
            }
        case .general:
            GeneralSettingsView()
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            "No Server Selected",
            systemImage: "server.rack",
            description: Text("Select a server on the left or add one with +. Add a separate server for each user.")
        )
    }

    @ViewBuilder
    private func contextMenu(for c: Connection) -> some View {
        Button("Connect") { manager.connect(c) }
        Button("Disconnect") { manager.disconnect(c) }
        Button("Open in Finder") { manager.openInFinder(c) }
        Divider()
        Button("Duplicate") { duplicate(c) }
        Button("Remove …", role: .destructive) { state.confirmDelete = c }
    }

    private func addServer() {
        let draft = Connection.blank()
        state.draftPassword = ""
        state.draft = draft
        state.selection = .new(draft.id)
    }

    /// Opens an unsaved copy (incl. password) – typically to change only the user.
    private func duplicate(_ c: Connection) {
        let draft = c.duplicate()
        state.draftPassword = Keychain.password(for: c.id) ?? ""
        state.draft = draft
        state.selection = .new(draft.id)
    }
}

private struct ServerSidebarRow: View {
    @EnvironmentObject private var manager: ConnectionManager
    let connection: Connection

    var body: some View {
        HStack(spacing: 10) {
            ServerTile(status: manager.status(of: connection), color: connection.color.color, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.name).lineLimit(1)
                Text(connection.displayUser)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Server editor

private final class EditorState: ObservableObject {
    @Published var draft: Connection
    @Published var password = ""
    @Published var alternateHosts: String
    @Published var portText: String
    @Published var reachability: String?
    @Published var checking = false
    @Published var available: [ShareBrowser.Share] = []
    @Published var loadingShares = false
    @Published var sharesError: String?
    @Published var search = ""
    @Published var newShare = ""

    init(_ c: Connection) {
        draft = c
        alternateHosts = c.alternateHosts.joined(separator: ", ")
        portText = c.port.map(String.init) ?? ""
    }
}

struct ServerEditor: View {
    @EnvironmentObject private var manager: ConnectionManager
    let original: Connection
    let isNew: Bool
    let onSaved: (UUID) -> Void
    let onDelete: () -> Void
    var onDuplicate: (() -> Void)?

    @StateObject private var s: EditorState
    private let hasStoredPassword: Bool

    init(original: Connection, isNew: Bool, initialPassword: String = "",
         onSaved: @escaping (UUID) -> Void, onDelete: @escaping () -> Void, onDuplicate: (() -> Void)? = nil) {
        self.original = original
        self.isNew = isNew
        self.onSaved = onSaved
        self.onDelete = onDelete
        self.onDuplicate = onDuplicate
        let state = EditorState(original)
        state.password = initialPassword
        _s = StateObject(wrappedValue: state)
        hasStoredPassword = Keychain.hasPassword(for: original.id)
    }

    // MARK: Derived state

    private var edited: Connection {
        var c = s.draft
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        c.host = c.host.trimmingCharacters(in: .whitespaces)
        c.username = c.username.trimmingCharacters(in: .whitespaces)
        c.domain = c.domain.trimmingCharacters(in: .whitespaces)
        c.alternateHosts = s.alternateHosts
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map(String.init)
        c.port = Int(s.portText.trimmingCharacters(in: .whitespaces))
        return c
    }

    private var isValid: Bool {
        let c = edited
        return !c.name.isEmpty
            && !c.host.isEmpty
            && (c.mountsAll || !c.shares.isEmpty)
            && (!c.needsPassword || (!c.username.isEmpty && (hasStoredPassword || !s.password.isEmpty)))
    }

    private var isDirty: Bool { edited != original || !s.password.isEmpty }

    private var canLoadShares: Bool {
        let c = edited
        return c.kind == .smb && !c.allHosts.isEmpty
            && (!c.needsPassword || (!c.username.isEmpty && (hasStoredPassword || !s.password.isEmpty)))
    }

    // MARK: Body

    var body: some View {
        Form {
            headerSection
            connectionSection
            loginSection
            sharesSection
            behaviourSection
            if !isNew {
                Section {
                    Button("Remove Server …", role: .destructive, action: onDelete)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(s.draft.name.isEmpty ? tr("New Server") : s.draft.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isNew {
                    Button("Cancel", action: onDelete)
                } else if isDirty {
                    Button("Revert", action: reset)
                }
                Button(isNew ? tr("Add") : tr("Save"), action: save)
                    .buttonStyle(.glassProminent)
                    .disabled(!isValid || !isDirty)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .onAppear {
            if s.available.isEmpty, let cached = manager.discovered[original.id] {
                s.available = cached
            }
            if s.available.isEmpty, !isNew, canLoadShares { loadShares() }
        }
    }

    private var headerSection: some View {
        let status = manager.status(of: original)
        return Section {
            HStack(spacing: 14) {
                ServerTile(status: isNew ? .disconnected : status, color: s.draft.color.color, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Name", text: $s.draft.name, prompt: Text("Name, e.g. Fileserver (Admin)"))
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                    Text(isNew ? tr("New server – not saved yet") : status.label)
                        .font(.callout)
                        .foregroundStyle(status.isProblem && !isNew ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                    ColorDotPicker(selection: $s.draft.color)
                        .padding(.top, 2)
                }
                Spacer()
                if !isNew {
                    if let onDuplicate {
                        Button(action: onDuplicate) {
                            Image(systemName: "plus.square.on.square")
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .help("Duplicate server – e.g. for another user")
                    }
                    let connected = manager.isKeptConnected(original)
                    Button(connected ? tr("Disconnect") : tr("Connect")) {
                        connected ? manager.disconnect(original) : manager.connect(original)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var connectionSection: some View {
        Section {
            Picker("Protocol", selection: $s.draft.kind) {
                ForEach(ServiceKind.allCases) { Text($0.label).tag($0) }
            }
            TextField("Server", text: $s.draft.host, prompt: Text("fileserver.example.com or 192.168.1.10"))
            TextField("Other Addresses", text: $s.alternateHosts, prompt: Text("optional, e.g. the address over VPN"))
            TextField("Port", text: $s.portText, prompt: Text(tr("Default (%lld)", s.draft.kind.defaultPort)))
            if s.draft.kind == .smb, s.draft.authMode == .password {
                Picker(selection: $s.draft.addressMode) {
                    ForEach(AddressMode.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Connect via")
                    Text(s.draft.connectsByIP
                         ? tr("By IP address – your Mac's own login can't take over.")
                         : tr("By server name – needed when the domain looks like “corp.example.com”."))
                }
            }
            LabeledContent("Reachability") {
                HStack(spacing: 8) {
                    if s.checking { ProgressView().controlSize(.small) }
                    if let result = s.reachability {
                        Text(result).foregroundStyle(.secondary)
                    }
                    Button("Check", action: checkReachability)
                        .disabled(edited.allHosts.isEmpty || s.checking)
                }
            }
        } header: {
            Text("Connection")
        } footer: {
            Text("Addresses are tried in order – so it works in the office and over VPN.")
                .foregroundStyle(.secondary)
        }
    }

    private var loginSection: some View {
        Section {
            if s.draft.kind == .smb {
                Picker("Login", selection: $s.draft.authMode) {
                    ForEach(AuthMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if s.draft.needsPassword {
                if s.draft.kind == .smb {
                    TextField("Domain", text: $s.draft.domain, prompt: Text("optional, e.g. CORP"))
                }
                TextField("User", text: $s.draft.username, prompt: Text("User name"))
                SecureField("Password", text: $s.password,
                            prompt: Text(hasStoredPassword ? tr("Saved – leave empty to keep it") : tr("Password")))
            }
        } header: {
            Text("Login")
        } footer: {
            Text(s.draft.needsPassword
                 ? tr("Always logs in as this user – even when the Mac is logged in to a domain. The password is kept in the keychain.")
                 : tr("Uses the Kerberos ticket of your Mac login. No password is stored."))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Shares

    private var visibleShares: [String] {
        let showHidden = s.draft.includeHiddenShares
        var names = s.available.filter { showHidden || !$0.isHidden }.map(\.name)
        names += s.draft.shares.filter { !names.contains($0) }
        let query = s.search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return names }
        return names.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func isSelected(_ share: String) -> Binding<Bool> {
        Binding(
            get: {
                s.draft.mountsAll ? !s.draft.excludedShares.contains(share) : s.draft.shares.contains(share)
            },
            set: { on in
                if s.draft.mountsAll {
                    if on {
                        s.draft.excludedShares.removeAll { $0 == share }
                    } else if !s.draft.excludedShares.contains(share) {
                        s.draft.excludedShares.append(share)
                    }
                } else {
                    if on {
                        if !s.draft.shares.contains(share) { s.draft.shares.append(share) }
                    } else {
                        s.draft.shares.removeAll { $0 == share }
                    }
                }
            }
        )
    }

    private func selectAll(_ on: Bool) {
        let names = visibleShares
        if s.draft.mountsAll {
            s.draft.excludedShares = on
                ? s.draft.excludedShares.filter { !names.contains($0) }
                : Array(Set(s.draft.excludedShares).union(names)).sorted()
        } else {
            s.draft.shares = on
                ? s.draft.shares + names.filter { !s.draft.shares.contains($0) }
                : s.draft.shares.filter { !names.contains($0) }
        }
    }

    private var selectedCount: Int {
        guard s.draft.mountsAll else { return s.draft.shares.count }
        return s.available
            .filter { (s.draft.includeHiddenShares || !$0.isHidden) && !s.draft.excludedShares.contains($0.name) }
            .count
    }

    private var sharesSection: some View {
        Section {
            if s.draft.kind == .smb {
                Toggle(isOn: $s.draft.mountAllShares) {
                    Text("Connect All Shares")
                    Text("Like on Windows: everything the server offers to this user. New shares are added automatically; you can deselect single ones below.")
                }
                if s.available.contains(where: \.isHidden) || s.draft.includeHiddenShares {
                    Toggle(isOn: $s.draft.includeHiddenShares) {
                        Text("Administrative Shares")
                        Text("C$, ADMIN$, Personal$ … – only useful for admin users")
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search shares", text: $s.search)
                    .textFieldStyle(.plain)
                if s.loadingShares {
                    ProgressView().controlSize(.small)
                }
                Menu {
                    Button("Select All") { selectAll(true) }
                    Button("Select None") { selectAll(false) }
                } label: {
                    Image(systemName: "checklist")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Selection")
                if s.draft.kind == .smb {
                    Button(action: loadShares) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canLoadShares || s.loadingShares)
                    .help("Load shares from the server")
                }
            }

            if let error = s.sharesError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            let rows = visibleShares
            if rows.isEmpty, !s.loadingShares {
                Text(s.draft.kind == .smb
                     ? (canLoadShares ? tr("No shares loaded yet – click ↻.") : tr("Enter server and login, then load the shares with ↻."))
                     : tr("Add the WebDAV path below."))
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.self) { share in
                ShareRow(
                    name: share,
                    comment: s.available.first { $0.name == share }?.comment ?? "",
                    mounted: !isNew && manager.isMounted(original, share: share),
                    denied: !isNew && manager.isDenied(original, share: share),
                    isOn: isSelected(share)
                )
            }

            if !s.draft.mountsAll {
                HStack {
                    TextField("Add path", text: $s.newShare,
                              prompt: Text(s.draft.kind == .smb ? tr("e.g. Data/Projects") : tr("e.g. remote.php/dav/files/user")))
                    Button("Add") {
                        let share = Connection.normalizedShare(s.newShare)
                        if !share.isEmpty, !s.draft.shares.contains(share) { s.draft.shares.append(share) }
                        s.newShare = ""
                    }
                    .disabled(Connection.normalizedShare(s.newShare).isEmpty)
                }
            }
        } header: {
            HStack {
                Text("Shares")
                Spacer()
                if selectedCount > 0 {
                    Text(tr("%lld selected", selectedCount)).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(tr("The shares appear in Finder in the folder “%@”, which has its own entry in the sidebar.", s.draft.name.isEmpty ? "…" : s.draft.name))
                .foregroundStyle(.secondary)
        }
    }

    private var behaviourSection: some View {
        Section("Behavior") {
            Toggle(isOn: $s.draft.autoConnect) {
                Text("Connect Automatically")
                Text("At login, after sleep and when the network changes")
            }
            if !isNew {
                LabeledContent("Location in Finder") {
                    Button {
                        manager.openInFinder(original)
                    } label: {
                        Label(manager.profileFolder(for: original).path(percentEncoded: false)
                                .replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                              systemImage: "folder")
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: Actions

    private func save() {
        let c = edited
        manager.save(c, password: s.password)
        s.password = ""
        onSaved(c.id)
    }

    private func reset() {
        s.draft = original
        s.password = ""
        s.alternateHosts = original.alternateHosts.joined(separator: ", ")
        s.portText = original.port.map(String.init) ?? ""
    }

    private func checkReachability() {
        let c = edited
        s.checking = true
        s.reachability = nil
        Task {
            var lines: [String] = []
            for host in c.allHosts {
                let ok = await Reachability.check(host: host, port: c.effectivePort)
                lines.append("\(ok ? "✓" : "✗") \(host)")
            }
            s.reachability = lines.joined(separator: "  ")
            s.checking = false
        }
    }

    private func loadShares() {
        let c = edited
        let typed = s.password
        let id = original.id
        s.loadingShares = true
        s.sharesError = nil
        Task {
            defer { s.loadingShares = false }
            let password: String? = typed.isEmpty ? await Task.detached { Keychain.password(for: id) }.value : typed
            guard let host = await Reachability.firstReachable(hosts: c.allHosts, port: c.effectivePort) else {
                s.sharesError = tr("Server not reachable")
                return
            }
            do {
                s.available = try await Task.detached {
                    try ShareBrowser.list(c, host: host, password: password)
                }.value
                if s.available.isEmpty { s.sharesError = tr("The server offers no shares") }
            } catch {
                s.sharesError = error.localizedDescription
            }
        }
    }
}

private struct ShareRow: View {
    let name: String
    let comment: String
    let mounted: Bool
    let denied: Bool
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: name.hasSuffix("$") ? "lock.shield" : "externaldrive.fill")
                    .foregroundStyle(mounted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                    if !comment.isEmpty {
                        Text(comment).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if denied {
                    Label("No access", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if mounted {
                    Text("Connected")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
        }
    }
}

// MARK: - General

private final class GeneralState: ObservableObject {
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var loginError: String?
    @Published var inSidebar = FinderSidebar.contains(ConnectionManager.mountRoot)
}

private struct GeneralSettingsView: View {
    @StateObject private var state = GeneralState()

    private var rootFolderDisplayPath: String {
        ConnectionManager.mountRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    IconTile(symbol: "externaldrive.connected.to.line.below.fill", color: .blue, size: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DriveDock").font(.title2.weight(.semibold))
                        Text(tr("Version %@", version)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Startup") {
                Toggle(isOn: $state.launchAtLogin) {
                    Text("Launch at Login")
                    Text("So your drives are there right after startup")
                }
                .onChange(of: state.launchAtLogin) { _, enabled in
                    do {
                        try LoginItem.set(enabled)
                        state.loginError = nil
                    } catch {
                        state.loginError = error.localizedDescription
                        state.launchAtLogin = LoginItem.isEnabled
                    }
                }
                if let error = state.loginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }

            Section("Finder") {
                LabeledContent("Folder") {
                    Button {
                        NSWorkspace.shared.open(ConnectionManager.mountRoot)
                    } label: {
                        Label(rootFolderDisplayPath, systemImage: "folder")
                    }
                    .buttonStyle(.link)
                }
                LabeledContent("Sidebar") {
                    if state.inSidebar {
                        Label("Added", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Add") {
                            FinderSidebar.add(ConnectionManager.mountRoot)
                            state.inSidebar = FinderSidebar.contains(ConnectionManager.mountRoot)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .safeAreaInset(edge: .bottom) { CreditFooter() }
    }
}

/// Small credit line at the bottom of the General page.
private struct CreditFooter: View {
    var body: some View {
        VStack(spacing: 3) {
            Text("Made by Sven Würth · Open source under the MIT License")
            Link(destination: AppInfo.repositoryURL) {
                Label {
                    Text(verbatim: "github.com/its-sven/DriveDock")
                } icon: {
                    Image(systemName: "arrow.up.right.square")
                }
            }
            .help("Open the project on GitHub")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}
