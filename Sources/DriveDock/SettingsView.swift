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
                            Text(draft.name.isEmpty ? "Neuer Server" : draft.name)
                        }
                        .tag(SidebarItem.new(draft.id))
                    }
                }
                Section {
                    HStack(spacing: 10) {
                        IconTile(symbol: "gearshape.fill", color: .gray, size: 26)
                        Text("Allgemein")
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
                        Label("Server hinzufügen", systemImage: "plus")
                    }
                    .help("Server hinzufügen")
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
            "„\(state.confirmDelete?.name ?? "")“ entfernen?",
            isPresented: Binding(get: { state.confirmDelete != nil }, set: { if !$0 { state.confirmDelete = nil } })
        ) {
            Button("Entfernen", role: .destructive) {
                if let c = state.confirmDelete {
                    manager.delete(c)
                    state.selection = manager.connections.first { $0.id != c.id }.map { .server($0.id) } ?? .general
                }
                state.confirmDelete = nil
            }
        } message: {
            Text("Alle Freigaben werden getrennt, der Eintrag in der Finder-Seitenleiste entfernt und das Passwort aus dem Schlüsselbund gelöscht.")
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
            "Kein Server ausgewählt",
            systemImage: "server.rack",
            description: Text("Wähle links einen Server oder lege mit + einen neuen an. Für jeden Benutzer legst du einen eigenen Server an.")
        )
    }

    @ViewBuilder
    private func contextMenu(for c: Connection) -> some View {
        Button("Verbinden") { manager.connect(c) }
        Button("Trennen") { manager.disconnect(c) }
        Button("Im Finder öffnen") { manager.openInFinder(c) }
        Divider()
        Button("Duplizieren") { duplicate(c) }
        Button("Entfernen …", role: .destructive) { state.confirmDelete = c }
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
                    Button("Server entfernen …", role: .destructive, action: onDelete)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(s.draft.name.isEmpty ? "Neuer Server" : s.draft.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isNew {
                    Button("Abbrechen", action: onDelete)
                } else if isDirty {
                    Button("Verwerfen", action: reset)
                }
                Button(isNew ? "Hinzufügen" : "Sichern", action: save)
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
                    TextField("Name", text: $s.draft.name, prompt: Text("Name, z. B. Fileserver (Admin)"))
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                    Text(isNew ? "Neuer Server – noch nicht gesichert" : status.label)
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
                        .help("Server duplizieren – z. B. für einen weiteren Benutzer")
                    }
                    let connected = manager.isKeptConnected(original)
                    Button(connected ? "Trennen" : "Verbinden") {
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
            Picker("Protokoll", selection: $s.draft.kind) {
                ForEach(ServiceKind.allCases) { Text($0.label).tag($0) }
            }
            TextField("Server", text: $s.draft.host, prompt: Text("fileserver.firma.local oder 192.168.1.10"))
            TextField("Weitere Adressen", text: $s.alternateHosts, prompt: Text("optional, z. B. Adresse über VPN"))
            TextField("Port", text: $s.portText, prompt: Text("Standard (\(s.draft.kind.defaultPort))"))
            if s.draft.kind == .smb, s.draft.authMode == .password {
                Picker(selection: $s.draft.addressMode) {
                    ForEach(AddressMode.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Verbinden über")
                    Text(s.draft.connectsByIP
                         ? "Über die IP-Adresse – dein Mac-Login kann die Anmeldung nicht übernehmen."
                         : "Über den Servernamen – nötig, wenn die Domäne wie „firma.local“ aussieht.")
                }
            }
            LabeledContent("Erreichbarkeit") {
                HStack(spacing: 8) {
                    if s.checking { ProgressView().controlSize(.small) }
                    if let result = s.reachability {
                        Text(result).foregroundStyle(.secondary)
                    }
                    Button("Prüfen", action: checkReachability)
                        .disabled(edited.allHosts.isEmpty || s.checking)
                }
            }
        } header: {
            Text("Verbindung")
        } footer: {
            Text("Adressen werden der Reihe nach probiert – so klappt es im Büro und über VPN.")
                .foregroundStyle(.secondary)
        }
    }

    private var loginSection: some View {
        Section {
            if s.draft.kind == .smb {
                Picker("Anmeldung", selection: $s.draft.authMode) {
                    Text("Benutzer & Passwort").tag(AuthMode.password)
                    Text("Domänen-Login").tag(AuthMode.kerberos)
                }
                .pickerStyle(.segmented)
            }
            if s.draft.needsPassword {
                if s.draft.kind == .smb {
                    TextField("Domäne", text: $s.draft.domain, prompt: Text("optional, z. B. FIRMA"))
                }
                TextField("Benutzer", text: $s.draft.username, prompt: Text("Benutzername"))
                SecureField("Passwort", text: $s.password,
                            prompt: Text(hasStoredPassword ? "Gesichert – leer lassen für unverändert" : "Passwort"))
            }
        } header: {
            Text("Anmeldung")
        } footer: {
            Text(s.draft.needsPassword
                 ? "Meldet sich immer mit diesem Benutzer an – auch wenn der Mac per Domäne angemeldet ist. Das Passwort liegt im Schlüsselbund."
                 : "Nutzt das Kerberos-Ticket deiner Mac-Anmeldung. Es wird kein Passwort gespeichert.")
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
                    Text("Alle Freigaben verbinden")
                    Text("Wie unter Windows: alles, was der Server diesem Benutzer anbietet. Neue Freigaben kommen automatisch dazu, einzelne kannst du unten abwählen.")
                }
                if s.available.contains(where: \.isHidden) || s.draft.includeHiddenShares {
                    Toggle(isOn: $s.draft.includeHiddenShares) {
                        Text("Administrative Freigaben")
                        Text("C$, ADMIN$, Personal$ … – nur für Admin-Benutzer sinnvoll")
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Freigaben durchsuchen", text: $s.search)
                    .textFieldStyle(.plain)
                if s.loadingShares {
                    ProgressView().controlSize(.small)
                }
                Menu {
                    Button("Alle auswählen") { selectAll(true) }
                    Button("Keine auswählen") { selectAll(false) }
                } label: {
                    Image(systemName: "checklist")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Auswahl")
                if s.draft.kind == .smb {
                    Button(action: loadShares) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canLoadShares || s.loadingShares)
                    .help("Freigaben vom Server laden")
                }
            }

            if let error = s.sharesError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            let rows = visibleShares
            if rows.isEmpty, !s.loadingShares {
                Text(s.draft.kind == .smb
                     ? (canLoadShares ? "Noch keine Freigaben geladen – tippe auf ↻." : "Gib Server und Anmeldung ein, dann lade die Freigaben mit ↻.")
                     : "Füge unten den WebDAV-Pfad hinzu.")
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
                    TextField("Pfad hinzufügen", text: $s.newShare,
                              prompt: Text(s.draft.kind == .smb ? "z. B. Daten/Projekte" : "z. B. remote.php/dav/files/benutzer"))
                    Button("Hinzufügen") {
                        let share = Connection.normalizedShare(s.newShare)
                        if !share.isEmpty, !s.draft.shares.contains(share) { s.draft.shares.append(share) }
                        s.newShare = ""
                    }
                    .disabled(Connection.normalizedShare(s.newShare).isEmpty)
                }
            }
        } header: {
            HStack {
                Text("Freigaben")
                Spacer()
                if selectedCount > 0 {
                    Text("\(selectedCount) ausgewählt").foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Die Freigaben erscheinen im Finder im Ordner „\(s.draft.name.isEmpty ? "…" : s.draft.name)“, der einen eigenen Eintrag in der Seitenleiste hat.")
                .foregroundStyle(.secondary)
        }
    }

    private var behaviourSection: some View {
        Section("Verhalten") {
            Toggle(isOn: $s.draft.autoConnect) {
                Text("Automatisch verbinden")
                Text("Beim Anmelden, nach dem Ruhezustand und bei Netzwerkwechseln")
            }
            if !isNew {
                LabeledContent("Ort im Finder") {
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
                s.sharesError = "Server nicht erreichbar"
                return
            }
            do {
                s.available = try await Task.detached {
                    try ShareBrowser.list(c, host: host, password: password)
                }.value
                if s.available.isEmpty { s.sharesError = "Der Server bietet keine Freigaben an" }
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
                    Label("Kein Zugriff", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if mounted {
                    Text("Verbunden")
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
                        Text("Version \(version)").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Start") {
                Toggle(isOn: $state.launchAtLogin) {
                    Text("Bei Anmeldung starten")
                    Text("Damit deine Laufwerke nach dem Hochfahren sofort da sind")
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
                LabeledContent("Ordner") {
                    Button {
                        NSWorkspace.shared.open(ConnectionManager.mountRoot)
                    } label: {
                        Label("~/Netzlaufwerke", systemImage: "folder")
                    }
                    .buttonStyle(.link)
                }
                LabeledContent("Seitenleiste") {
                    if state.inSidebar {
                        Label("Eingetragen", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Hinzufügen") {
                            FinderSidebar.add(ConnectionManager.mountRoot)
                            state.inSidebar = FinderSidebar.contains(ConnectionManager.mountRoot)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Allgemein")
    }
}
