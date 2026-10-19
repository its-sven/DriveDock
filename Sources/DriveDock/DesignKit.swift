import SwiftUI

/// Rounded, gradient-filled symbol tile as used in System Settings.
struct IconTile: View {
    let symbol: String
    var color: Color = .blue
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: color.opacity(0.25), radius: size * 0.08, y: size * 0.04)
    }
}

/// Server tile with a small status dot in the corner.
struct ServerTile: View {
    let status: ConnectionStatus
    var color: Color = .blue
    var size: CGFloat = 36

    var body: some View {
        IconTile(symbol: "server.rack", color: color, size: size)
            .overlay(alignment: .bottomTrailing) {
                StatusDot(status: status, size: size * 0.32)
                    .offset(x: size * 0.1, y: size * 0.1)
            }
    }
}

struct StatusDot: View {
    let status: ConnectionStatus
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(status.color.gradient)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.background, lineWidth: max(1.5, size * 0.18)))
    }
}

extension ConnectionStatus {
    var shortLabel: String {
        switch self {
        case .disconnected: tr("Not connected")
        case .paused: tr("Disconnected")
        case .connecting: tr("Connecting …")
        case .connected: tr("Connected")
        case .partial(let mounted, let total, _): tr("%lld of %lld connected", mounted, total)
        case .unreachable: tr("Not reachable")
        case .needsPassword: tr("Password missing")
        case .authFailed: tr("Login failed")
        case .error: tr("Error")
        }
    }

    var isPartial: Bool {
        if case .partial = self { return true }
        return false
    }
}

/// Small capsule for a share: filled when mounted, dimmed otherwise, lock when access is denied.
struct ShareChip: View {
    let name: String
    let mounted: Bool
    let denied: Bool
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: denied ? "lock.fill" : (mounted ? "externaldrive.fill" : "externaldrive"))
                    .font(.system(size: 9, weight: .semibold))
                Text(name)
                    .lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(mounted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .background(
                Capsule().fill(mounted ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.fill.tertiary))
            )
        }
        .buttonStyle(.plain)
        .disabled(!mounted)
        .help(denied ? tr("No access for this user") : (mounted ? tr("Open in Finder") : tr("Not connected")))
    }
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                let y = row.y + row.height + spacing
                rows.append(Row(y: y))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// Row of color dots like the accent color picker in System Settings.
struct ColorDotPicker: View {
    @Binding var selection: ServerColor

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ServerColor.allCases) { option in
                Button {
                    selection = option
                } label: {
                    Circle()
                        .fill(option.color.gradient)
                        .frame(width: 18, height: 18)
                        .overlay {
                            if option == selection {
                                Circle().fill(.white).frame(width: 6, height: 6)
                            }
                        }
                        .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help(option.label)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
    }
}
