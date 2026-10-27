import AppKit
import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var manager: ConnectionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 12) {
            header

            if manager.connections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(manager.connections) { connection in
                            ServerCard(connection: connection)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 440)
            }

            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    private var summary: String {
        let servers = manager.connections.count
        let shares = manager.mountedShareCount
        let serverText = servers == 1 ? tr("1 server") : tr("%lld servers", servers)
        let shareText = shares == 1 ? tr("1 share connected") : tr("%lld shares connected", shares)
        return "\(serverText) · \(shareText)"
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "externaldrive.connected.to.line.below.fill", color: .blue, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("DriveDock").font(.headline)
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                manager.connectAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Connect all now")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("No servers yet").font(.headline)
            Text("Add a server with a user – its shares will then appear in Finder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Server") { openManager() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var footer: some View {
        HStack {
            Button {
                openManager()
            } label: {
                Label("Manage Servers …", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.glass)

            Button {
                NSWorkspace.shared.open(ConnectionManager.mountRoot)
            } label: {
                Label(ConnectionManager.mountRoot.lastPathComponent, systemImage: "folder")
            }
            .buttonStyle(.glass)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Quit DriveDock")
        }
    }

    private func openManager() {
        openWindow(id: WindowID.connections)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ServerCard: View {
    @EnvironmentObject private var manager: ConnectionManager
    let connection: Connection

    private static let maxChips = 10

    var body: some View {
        let status = manager.status(of: connection)
        let all = manager.activeShares(of: connection)
        let shares = all.filter { !manager.isDenied(connection, share: $0) }
        let deniedCount = all.count - shares.count

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ServerTile(status: status, color: connection.color.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connection.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle(status))
                        .font(.caption)
                        .foregroundStyle(status.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if status == .connecting {
                    ProgressView().controlSize(.small)
                }
                Button {
                    manager.openInFinder(connection)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help("Open in Finder")

                Toggle("Connected", isOn: Binding(
                    get: { manager.isKeptConnected(connection) },
                    set: { on in on ? manager.connect(connection) : manager.disconnect(connection) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help("Keep connected")
            }

            if !all.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(shares.prefix(Self.maxChips), id: \.self) { share in
                        ShareChip(
                            name: share,
                            mounted: manager.isMounted(connection, share: share),
                            denied: false
                        ) {
                            manager.openInFinder(connection, share: share)
                        }
                    }
                    if shares.count > Self.maxChips {
                        Text(verbatim: "+\(shares.count - Self.maxChips)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                    }
                    if deniedCount > 0 {
                        Label(tr("%lld without access", deniedCount), systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .help("The server lists these shares, but this user may not open them.")
                    }
                }
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
        .contentShape(.rect(cornerRadius: 16))
        .onTapGesture(count: 2) { manager.openInFinder(connection) }
    }

    private func subtitle(_ status: ConnectionStatus) -> String {
        switch status {
        case .connected, .connecting, .disconnecting, .disconnected, .paused:
            "\(connection.displayUser) · \(status.shortLabel)"
        default:
            status.label
        }
    }
}
