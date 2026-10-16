import AppKit
import SwiftUI

@main
struct DriveDockApp: App {
    @StateObject private var manager = ConnectionManager()

    init() {
        // Login item and a manual start can race; keep the instance that came first.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        if !others.isEmpty {
            others.first?.activate()
            exit(0)
        }
        LoginItem.enableOnFirstLaunch()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(manager)
        } label: {
            Image(systemName: manager.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("DriveDock", id: WindowID.connections) {
            SettingsView()
                .environmentObject(manager)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 900, height: 640)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
    }
}

enum WindowID {
    static let connections = "connections"
}
